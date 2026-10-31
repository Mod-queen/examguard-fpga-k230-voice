`timescale 1ns/1ps
// Entire synthesizable writer/directory/reader/single-DMA chain. TB supplies
// only source frames, ordered fences, event/read requests and consumer ready.
module history_store_axi_case #(parameter FP=37,BURST=1)(output reg test_done=0);
    localparam STRIDE=((FP+7)/8)*16,BASE=4080;
    reg clk=0,rst=1;
    always #5 clk=~clk;
    reg frame_valid=0,frame_fence=0;
    wire frame_ready;
    reg [95:0] frame_meta=0;
    reg pixel_valid=0,pixel_last=0;
    reg [15:0] pixel_data=0;
    wire pixel_ready,write_result_valid;
    reg write_result_ready=0;
    wire [95:0] write_result_meta;
    wire [2:0] write_result_code;
    wire fence_done,fence_ok;
    reg request_valid=0;
    wire request_ready,accepted;
    reg [255:0] request_event=0;
    wire accepted_window;
    wire [31:0] accepted_token;
    reg read_valid=0,read_window=0;
    reg [31:0] read_token=0;
    wire read_ready,out_valid,out_sof,out_last;
    wire [15:0] out_data;
    wire [95:0] out_meta;
    wire [255:0] out_event;
    wire [31:0] out_index;
    reg out_ready=0,result_ready=0;
    wire result_valid,result_ok,result_truncated,result_capture_error,result_window,done,done_ok;
    wire [2:0] result_code,faults;
    wire [31:0] result_frames,result_token;
    wire [6:0] protected_slots;
    wire token_exhausted,window_token_exhausted;
    wire [31:0] frames_committed,frames_dropped,reserve_rejected,write_failed,write_beats,read_beats;
    `include "axi_frame_tb_wires.vh"
    reg hold_b=0,inject_b=0,inject_r=0;
    reg dir_seal_valid=0;
    wire dir_seal_ready;
    reg [63:0] dir_seal_time=0;
    wire directory_writer_pending;
    wire [1:0] directory_active_mask,directory_closed_mask;
    history_store_axi #(.FRAME_PIXELS(FP),.SLOTS(7),.WINDOWS(2),.PRE_MS(100),.POST_MS(100),.BASE_ADDR(BASE),.BURST(BURST)) dut(.*);
    axi_frame_slave_model memory(.*);
    integer simultaneous=0,checked_pixels=0,checked_results=0;
    reg [31:0] token_a,token_b;
    reg [31:0] old_token_a;
    reg handle_a,handle_b;
    reg [6:0] refs_a,refs_b;
    reg [255:0] event_a,event_b;
    integer i,aw_before,ar_before,concurrent_cycles;
    always @(posedge clk) if(!rst) begin
        if(dut.wr_busy && dut.rd_busy) simultaneous=simultaneous+1;
        if(m_axi_awvalid && m_axi_awready) begin
            if(protected_slots[(m_axi_awaddr-BASE)/STRIDE]) $fatal(1,"FAIL: AXI AW touches protected pixel region");
        end
        if(dut.seal_valid && dut.seal_ready && (dut.wr_busy || dut.directory.writer_pending))
            $fatal(1,"FAIL: fence overtook DMA reservation");
    end
    task automatic reset_all;
        begin
            @(negedge clk);rst=1;frame_valid=0;pixel_valid=0;request_valid=0;read_valid=0;
            out_ready=0;result_ready=0;write_result_ready=0;hold_b=0;inject_b=0;inject_r=0;
            repeat(4) @(negedge clk);rst=0;simultaneous=0;
        end
    endtask
    task automatic command(input integer stamp,input fence);
        begin
            @(negedge clk);frame_valid=1;frame_fence=fence;frame_meta={32'(stamp),64'(stamp)};
            @(posedge clk);while(!frame_ready) @(posedge clk);
            @(negedge clk);frame_valid=0;
        end
    endtask
    task automatic frame(input integer stamp,input [2:0] expected_code);
        integer p;
        begin
            command(stamp,0);
            for(p=0;p<FP;p=p+1) begin
                @(negedge clk);pixel_valid=1;pixel_last=p==FP-1;pixel_data=stamp+p;
                @(posedge clk);while(!pixel_ready) @(posedge clk);
                @(negedge clk);pixel_valid=0;
            end
            pixel_last=0;
            wait(write_result_valid);#1;
            repeat(7) begin
                @(negedge clk);
                if(write_result_code!=expected_code || write_result_meta!=={32'(stamp),64'(stamp)} || frame_ready)
                    $fatal(1,"FAIL: write result stamp%0d code%0d expected%0d",stamp,write_result_code,expected_code);
            end
            write_result_ready=1;@(negedge clk);write_result_ready=0;
        end
    endtask
    task automatic fence(input integer stamp);
        begin command(stamp,1);wait(fence_done);#1;if(!fence_ok) $fatal(1,"FAIL: fence rejected");end
    endtask
    task automatic request(input integer stamp,input integer uid,output reg h,output reg [31:0] t,output reg [255:0] e);
        begin
            e={32'hac750001,32'd5,32'd3,64'(uid),64'(stamp),8'd1,8'd0,16'h3750};
            @(negedge clk);request_event=e;request_valid=1;
            @(posedge clk);while(!request_ready) @(posedge clk);
            @(negedge clk);request_valid=0;
            if(!accepted) $fatal(1,"FAIL: request response missing");
            h=accepted_window;t=accepted_token;
            repeat(10) @(negedge clk);
        end
    endtask
    task automatic start_read(input h,input [31:0] t);
        begin
            @(negedge clk);read_valid=1;read_window=h;read_token=t;
            @(posedge clk);while(!read_ready) @(posedge clk);
            @(negedge clk);read_valid=0;
        end
    endtask
    task automatic consume(input integer first_stamp,input integer count,input [255:0] e,input [6:0] required_refs);
        integer f,p;
        reg [401:0] held;
        begin
            for(f=0;f<count;f=f+1) for(p=0;p<FP;p=p+1) begin
                wait(out_valid);#1;held={out_event,out_meta,out_index,out_data,out_sof,out_last};
                repeat(15) begin
                    @(negedge clk);
                    if(!out_valid || {out_event,out_meta,out_index,out_data,out_sof,out_last}!==held ||
                       (protected_slots & required_refs)!==required_refs || result_valid)
                        $fatal(1,"FAIL: output hold/reference lost during concurrent writer");
                end
                if(out_event!==e || out_meta!=={32'(first_stamp+f*50),64'(first_stamp+f*50)} ||
                   out_index!=f || out_sof!=(p==0) || out_last!=(p==FP-1) || out_data!=first_stamp+f*50+p)
                    $fatal(1,"FAIL: data/context changed during shared DMA read");
                checked_pixels=checked_pixels+1;
                out_ready=1;@(negedge clk);out_ready=0;
            end
        end
    endtask
    task automatic consume_result(input [2:0] code,input integer count,input h,input [31:0] token,input clean,input [6:0] required_refs);
        begin
            wait(result_valid);#1;
            repeat(35) begin
                @(negedge clk);
                if(!result_valid || result_code!=code || result_frames!=count || result_ok!==clean ||
                   result_window!=h || result_token!=token || (protected_slots & required_refs)!==required_refs || read_ready)
                    $fatal(1,"FAIL: window result/reference stability code%0d count%0d",result_code,result_frames);
            end
            result_ready=1;@(negedge clk);result_ready=0;
            if(!done) wait(done);
            #1;if(done_ok!==clean) $fatal(1,"FAIL: release verdict");
            checked_results=checked_results+1;
        end
    endtask
    initial begin
        reset_all();
        frame(100,0);frame(150,0);frame(200,0);frame(250,0);frame(300,0);
        request(200,1,handle_a,token_a,event_a);request(250,2,handle_b,token_b,event_b);
        if(handle_a==handle_b || token_a==token_b || request_ready) $fatal(1,"FAIL: distinct two-window allocation");
        // Hold a third source request against a full window table while frames
        // and their fence progress. A blocked event must not starve the writer.
        @(negedge clk);request_valid=1;request_event=256'h1234;
        frame(350,0);frame(400,0);fence(400);
        if(request_ready || accepted) $fatal(1,"FAIL: full table accepted third event");
        @(negedge clk);request_valid=0;
        refs_a=dut.directory.refs[handle_a];refs_b=dut.directory.refs[handle_b];
        if($countones(refs_a & refs_b)!=4) $fatal(1,"FAIL: overlap did not share four frames");
        fork
            begin for(i=0;i<60;i=i+1) frame(450+i*50,0);end
            begin
                start_read(handle_a,token_a);consume(100,5,event_a,refs_a);consume_result(0,5,handle_a,token_a,1,refs_a);
                if((protected_slots & refs_b)!==refs_b) $fatal(1,"FAIL: release A lost B shared refs");
                // Freed index is reused while B still owns shared frames.
                // Read command with old token must not read the new identity.
                old_token_a=token_a;
                request(200,3,handle_a,token_a,event_a);
                ar_before=memory.ar_count;
                start_read(handle_a,old_token_a);consume_result(1,0,handle_a,old_token_a,0,refs_b);
                if(memory.ar_count!=ar_before || !dut.directory.active[handle_a] ||
                   dut.directory.window_tokens[handle_a]!=token_a) $fatal(1,"FAIL: stale command affected reused window");
                start_read(handle_b,token_b);consume(150,5,event_b,refs_b);consume_result(0,5,handle_b,token_b,1,refs_b);
            end
        join
        if(!simultaneous || faults || frames_committed!=67 || frames_dropped) $fatal(1,"FAIL: concurrent pipeline progress");
        concurrent_cycles=simultaneous;
        // Remaining third window can be truncated by churn before its request.
        // Retained set may vary with writer timing, so reset before directed errors.
        reset_all();frame(100,0);frame(150,0);request(200,4,handle_a,token_a,event_a);
        inject_b=1;frame(200,2);inject_b=0;frame(250,0);fence(300);
        refs_a=dut.directory.refs[handle_a];
        if(!dut.directory.capture_error[handle_a] || write_failed!=1) $fatal(1,"FAIL: failed B not recorded");
        start_read(handle_a,token_a);
        // Failed source200 omitted; three valid source times100,150,250.
        consume(100,2,event_a,refs_a);
        // Consume final frame manually because its index remains2 across gap.
        for(i=0;i<FP;i=i+1) begin
            wait(out_valid);#1;
            if(out_index!=2 || out_meta[63:0]!=250 || out_data!=250+i) $fatal(1,"FAIL: failed frame published");
            checked_pixels=checked_pixels+1;
            @(negedge clk);out_ready=1;@(negedge clk);out_ready=0;
        end
        consume_result(0,3,handle_a,token_a,0,refs_a);
        // Fresh retained window, injected R error: read data still validated,
        // but result never success and release occurs after result consumption.
        request(200,5,handle_b,token_b,event_b);refs_b=dut.directory.refs[handle_b];
        inject_r=1;start_read(handle_b,token_b);consume(100,2,event_b,refs_b);
        for(i=0;i<FP;i=i+1) begin
            wait(out_valid);#1;if(out_index!=2 || out_data!=250+i) $fatal(1,"FAIL: R error data mismatch");
            checked_pixels=checked_pixels+1;
            @(negedge clk);out_ready=1;@(negedge clk);out_ready=0;
        end
        consume_result(4,3,handle_b,token_b,0,refs_b);inject_r=0;
        if(protected_slots || faults) $fatal(1,"FAIL: error-window cleanup");
        // Two overlapping windows protect ALL seven slots. A queued frame
        // must drain with code1 while the first read's result is held; freeing
        // only A then makes exactly its exclusive prefix available to writer.
        reset_all();
        for(i=0;i<7;i=i+1) frame(100+i*50,0);
        request(200,8,handle_a,token_a,event_a);request(300,9,handle_b,token_b,event_b);fence(400);
        refs_a=dut.directory.refs[handle_a];refs_b=dut.directory.refs[handle_b];
        if(protected_slots!=127) $fatal(1,"FAIL: full protection fixture");
        start_read(handle_a,token_a);consume(100,5,event_a,refs_a);wait(result_valid);
        aw_before=memory.aw_count;frame(450,1);
        if(memory.aw_count!=aw_before || frames_dropped!=1 || reserve_rejected!=1 || !result_valid || protected_slots!=127)
            $fatal(1,"FAIL: capacity reject overwrote pending result references");
        consume_result(0,5,handle_a,token_a,1,refs_a);
        fork
            frame(500,0);
            begin start_read(handle_b,token_b);consume(200,5,event_b,refs_b);consume_result(0,5,handle_b,token_b,1,refs_b);end
        join
        if(protected_slots || faults || frames_committed!=8) $fatal(1,"FAIL: capacity release recovery");
        // Cancel an actual simultaneous read + write waiting for B.
        reset_all();frame(100,0);request(100,6,handle_a,token_a,event_a);fence(200);
        start_read(handle_a,token_a);wait(out_valid);
        hold_b=1;
        command(250,0);
        for(i=0;i<(FP<BURST*8?FP:BURST*8);i=i+1) begin
            @(negedge clk);pixel_valid=1;pixel_last=i==FP-1;pixel_data=250+i;
            @(posedge clk);while(!pixel_ready) @(posedge clk);
            @(negedge clk);pixel_valid=0;
        end
        wait(dut.wr_busy && dut.rd_busy && m_axi_bready);reset_all();repeat(20) @(negedge clk);
        if(out_valid || result_valid || write_result_valid || protected_slots || dut.wr_busy || dut.rd_busy) $fatal(1,"FAIL: reset leaked old work");
        frame(100,0);request(200,7,handle_a,token_a,event_a);fence(300);
        refs_a=dut.directory.refs[handle_a];start_read(handle_a,token_a);consume(100,1,event_a,refs_a);
        consume_result(0,1,handle_a,token_a,1,refs_a);
        $display("PASS: history_store_axi FP=%0d writer+reader+token directory+oneDMA overlap/concurrent/R-Berrors/held results/capacity/stale/reset pixels=%0d results=%0d concurrentCycles=%0d",FP,checked_pixels,checked_results,concurrent_cycles);
        test_done=1;
    end
    initial begin #3000000;if(!test_done) $fatal(1,"FAIL: store timeout FP%0d W%0d R%0d",FP,dut.writer.state,dut.reader.state);end
endmodule
module history_store_axi_tb;
    wire a,b,c;
    history_store_axi_case #(.FP(1)) one(a);
    history_store_axi_case #(.FP(37)) tail(b);
    history_store_axi_case #(.FP(269),.BURST(32)) burst(c);
    initial begin wait(a && b && c);$display("PASS: history_store_axi ALL");$finish;end
endmodule
