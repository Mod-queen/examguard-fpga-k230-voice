`timescale 1ns/1ps
// End-to-end scheduled history plane: real writer/directory/token reader/one
// DMA + automatic seal (ordered fence), integrated gap journal and merged
// result. TB supplies source frames, fences, event requests and gap records.
module history_scheduler_case #(
    parameter integer FP=37,
    parameter integer GDEPTH=16,
    parameter integer SCENARIO=0
)(output reg test_done=0);
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
    wire [0:0] accepted_window;
    wire [31:0] accepted_token;
    reg fence_valid=0;
    reg [63:0] fence_time=0;
    reg gap_valid=0;
    wire gap_ready;
    reg [95:0] gap_meta=0;
    reg [7:0] gap_reason=0;
    reg out_ready=0,result_ready=0;
    wire out_valid,out_sof,out_last;
    wire [15:0] out_data;
    wire [95:0] out_meta;
    wire [255:0] out_event;
    wire [31:0] out_index;
    wire result_valid,result_ok,result_truncated,result_capture_error,result_coverage_ok;
    wire result_gap_unknown,result_gap_bad_range;
    wire [2:0] result_code;
    wire [31:0] result_frames,result_token,result_gap_count;
    wire [0:0] result_window;
    wire [63:0] result_lower,result_upper;
    wire [95:0] result_gap_first_meta,result_gap_last_meta;
    wire [7:0] result_gap_first_reason,result_gap_last_reason;
    wire [255:0] result_event;
    wire scheduler_halted,scheduler_protocol_fault,journal_halted;
    wire [1:0] pending_windows;
    wire [63:0] sealed_time;
    wire [31:0] gap_recorded,gap_evicted;
    wire [6:0] protected_slots;
    wire [2:0] faults;
    wire token_exhausted,window_token_exhausted;
    wire [31:0] frames_committed,frames_dropped,reserve_rejected,write_failed,write_beats,read_beats;
    wire done,done_ok;
    `include "axi_frame_tb_wires.vh"
    reg hold_b=0,inject_b=0,inject_r=0;
    history_scheduled_store #(.FRAME_PIXELS(FP),.SLOTS(7),.WINDOWS(2),.BURST(1),.GAP_DEPTH(GDEPTH),
        .PRE_MS(100),.POST_MS(100),.BASE_ADDR(BASE)) dut(.*);
    axi_frame_slave_model memory(.*);
    integer checked_pixels=0,checked_results=0;
    reg [0:0] h_a,h_b;
    reg [31:0] tok_a,tok_b;
    reg [255:0] e_a,e_b;
    always @(posedge clk) if(!rst) begin
        if(dut.store_read_valid && !dut.directory_closed_mask[dut.store_read_window])
            $fatal(1,"FAIL: reader started before directory closed");
        if(dut.store_seal_valid && dut.store_seal_ready && dut.directory_writer_pending)
            $fatal(1,"FAIL: seal overtook an unfinished writer");
        if(m_axi_awvalid && m_axi_awready && protected_slots[(m_axi_awaddr-BASE)/STRIDE])
            $fatal(1,"FAIL: AXI AW touched a referenced pixel slot");
    end
    task automatic reset_all;
        begin
            @(negedge clk);rst=1;frame_valid=0;pixel_valid=0;request_valid=0;fence_valid=0;gap_valid=0;
            out_ready=0;result_ready=0;write_result_ready=0;
            repeat(4) @(negedge clk);rst=0;
        end
    endtask
    task automatic command(input integer stamp,input is_fence);
        begin
            @(negedge clk);frame_valid=1;frame_fence=is_fence;frame_meta={32'(stamp),64'(stamp)};
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
        begin
            @(negedge clk);fence_valid=1;fence_time=64'(stamp);
            @(posedge clk);@(negedge clk);fence_valid=0;
        end
    endtask
    task automatic wait_seal(input integer stamp);
        integer n;
        begin
            n=0;
            while(sealed_time<stamp && n<2000) begin @(negedge clk);n=n+1;end
            if(sealed_time<stamp) $fatal(1,"FAIL: seal did not advance to %0d",stamp);
        end
    endtask
    task automatic request(input integer stamp,input integer uid,
                           output reg [0:0] h,output reg [31:0] t,output reg [255:0] e);
        begin
            e={32'hac750001,32'd5,32'd3,64'(uid),64'(stamp),8'd1,8'd0,16'h3750};
            @(negedge clk);
            while(!request_ready) @(negedge clk);
            request_event=e;request_valid=1;
            @(posedge clk);
            while(!accepted) @(posedge clk);
            @(negedge clk);
            h=accepted_window;t=accepted_token;request_valid=0;
            repeat(4) @(negedge clk);
        end
    endtask
    task automatic gap_record(input integer stamp,input [7:0] reason);
        begin
            @(negedge clk);
            while(!gap_ready) @(negedge clk);
            gap_valid=1;gap_meta={32'(stamp/50),64'(stamp)};gap_reason=reason;
            @(posedge clk);@(negedge clk);gap_valid=0;
        end
    endtask
    task automatic consume_pixels(input integer first_stamp,input integer stride,
                                  input integer count,input [255:0] e);
        integer f,p;
        begin
            for(f=0;f<count;f=f+1) for(p=0;p<FP;p=p+1) begin
                wait(out_valid);#1;
                if(out_event!==e || out_meta!=={32'(first_stamp+f*stride),64'(first_stamp+f*stride)} ||
                   out_index!=f || out_sof!=(p==0) || out_last!=(p==FP-1) ||
                   out_data!=(first_stamp+f*stride+p))
                    $fatal(1,"FAIL: scheduled read data/context f%0d p%0d",f,p);
                repeat(3) @(negedge clk);
                if(!out_valid) $fatal(1,"FAIL: pixel not held under backpressure");
                checked_pixels=checked_pixels+1;
                out_ready=1;@(negedge clk);out_ready=0;
            end
        end
    endtask
    task automatic consume_result(input [2:0] code,input integer count,input [0:0] h,
                                  input [31:0] token,input integer gap_count,input unknown,
                                  input trunc,input coverage,input [63:0] lower,input [63:0] upper,
                                  input [255:0] e);
        begin
            wait(result_valid);#1;
            if(result_code!=code || result_frames!=count || result_window!=h || result_token!=token ||
               result_gap_count!=gap_count || result_gap_unknown!==unknown || result_gap_bad_range ||
               result_truncated!==trunc || result_capture_error ||
               result_coverage_ok!==coverage || result_ok!==(code==0 && !trunc) ||
               result_lower!==lower || result_upper!==upper || result_event!==e)
                $fatal(1,"FAIL: merged result code%0d frames%0d gap%0d unk%0d trunc%0d cov%0d",
                       result_code,result_frames,result_gap_count,result_gap_unknown,result_truncated,result_coverage_ok);
            repeat(20) begin
                @(negedge clk);
                if(!result_valid || result_code!=code || result_frames!=count || result_gap_count!=gap_count ||
                   result_gap_unknown!==unknown || result_coverage_ok!==coverage ||
                   result_lower!==lower || result_upper!==upper || result_event!==e)
                    $fatal(1,"FAIL: merged result changed while held");
            end
            result_ready=1;@(negedge clk);result_ready=0;
            wait(done);#1;
            if(done_ok!==(code==0 && !trunc))
                $fatal(1,"FAIL: release verdict after merged result code%0d trunc%0d doneok%0d",code,trunc,done_ok);
            checked_results=checked_results+1;
            repeat(3) @(negedge clk);
        end
    endtask
    initial begin
        if(SCENARIO==0) begin
            reset_all();
            frame(100,0);frame(150,0);frame(200,0);frame(250,0);frame(300,0);frame(350,0);
            request(200,1,h_a,tok_a,e_a);request(250,2,h_b,tok_b,e_b);
            if(pending_windows!=2 || request_ready) $fatal(1,"FAIL: bounded handle table not full");
            @(negedge clk);request_valid=1;request_event=256'h1234;
            @(posedge clk);#1;
            if(request_ready || accepted) $fatal(1,"FAIL: third event accepted while handles full");
            @(negedge clk);request_valid=0;
            gap_record(300,8'h01);
            fence(300);wait_seal(300);
            // Window A [100,300] closes and must be read automatically.
            consume_pixels(100,50,5,e_a);
            consume_result(0,5,h_a,tok_a,1,0,0,0,100,300,e_a);
            repeat(20) @(negedge clk);
            if(result_valid || dut.store_read_valid) $fatal(1,"FAIL: closed-fence window B read early");
            frame(400,0);
            fence(400);wait_seal(400);
            consume_pixels(150,50,5,e_b);
            consume_result(0,5,h_b,tok_b,1,0,0,0,150,350,e_b);
            if(pending_windows || scheduler_halted || scheduler_protocol_fault || faults ||
               frames_committed!=7) $fatal(1,"FAIL: normal scheduled completion");
            // Ordered-fence regression must halt, then common reset recovers.
            reset_all();
            fence(400);wait_seal(400);
            fence(300);repeat(6) @(negedge clk);
            if(!scheduler_halted || !scheduler_protocol_fault) $fatal(1,"FAIL: fence regression not halted");
            reset_all();
            frame(100,0);frame(200,0);request(200,3,h_a,tok_a,e_a);
            fence(300);wait_seal(300);
            consume_pixels(100,100,2,e_a);
            consume_result(0,2,h_a,tok_a,0,0,0,1,100,300,e_a);
            if(scheduler_halted || faults) $fatal(1,"FAIL: recovery after fence halt");
            // Out-of-order gap records halt the epoch.
            reset_all();
            gap_record(300,8'h02);gap_record(250,8'h02);
            repeat(6) @(negedge clk);
            if(!journal_halted || !scheduler_halted || !scheduler_protocol_fault)
                $fatal(1,"FAIL: gap order regression not halted");
        end else if(SCENARIO==1) begin
            // Bounded journal: lower range intersects an evicted point gap.
            reset_all();
            frame(100,0);frame(150,0);frame(200,0);frame(250,0);frame(300,0);
            gap_record(110,8'h03);gap_record(120,8'h03);gap_record(130,8'h03);
            request(200,4,h_a,tok_a,e_a);fence(300);wait_seal(300);
            consume_pixels(100,50,5,e_a);
            consume_result(0,5,h_a,tok_a,2,1,0,0,100,300,e_a);
            if(result_gap_first_meta[63:0]!=120 || result_gap_last_meta[63:0]!=130 ||
               result_gap_first_reason!=8'h03 || result_gap_last_reason!=8'h03 ||
               gap_recorded!=3 || gap_evicted!=1)
                $fatal(1,"FAIL: evicted gap summary mismatch");
            if(scheduler_halted || faults) $fatal(1,"FAIL: eviction is unknown, not a halt");
        end else if(SCENARIO==3) begin
            // Repeated overlapping burst pairs across multiple directory wraps.
            // Slow output holds ALL seven slots, rejecting capture until release.
            for(integer round=0;round<12;round=round+1) begin
                reset_all();
                for(integer n=0;n<7;n=n+1) frame(100+n*50,0);
                request(250,round*2+20,h_a,tok_a,e_a);
                request(300,round*2+21,h_b,tok_b,e_b);
                // A protects150..350; B200..400. Fill previously unprotected100
                // slot with450, then every candidate slot is protected except it.
                frame(450,0);
                fence(400);wait_seal(400);
                consume_pixels(150,50,5,e_a);
                consume_result(0,5,h_a,tok_a,0,0,0,1,150,350,e_a);
                consume_pixels(200,50,5,e_b);
                consume_result(0,5,h_b,tok_b,0,0,0,1,200,400,e_b);
                if(pending_windows || protected_slots || faults || scheduler_halted)
                    $fatal(1,"FAIL: stress round leaked references %0d",round);
            end
            // Cancel while a physical B response remains held. Common reset is
            // the contract for this local slave fixture; top AXI guard separately
            // verifies draining without cancelling the shared video slave.
            reset_all();hold_b=1;
            fork
                frame(100,0);
                begin
                    wait(memory.responding);repeat(10) @(negedge clk);
                    reset_all();hold_b=0;
                end
            join_any
            disable fork;
            frame(100,0);frame(200,0);request(200,100,h_a,tok_a,e_a);fence(300);wait_seal(300);
            consume_pixels(100,100,2,e_a);
            consume_result(0,2,h_a,tok_a,0,0,0,1,100,300,e_a);
        end else begin
            // A window accepted after the retained history is truncated.
            reset_all();
            frame(100,0);frame(150,0);frame(200,0);frame(250,0);frame(300,0);
            request(50,5,h_a,tok_a,e_a);fence(150);wait_seal(150);
            consume_pixels(100,50,2,e_a);
            consume_result(0,2,h_a,tok_a,0,0,1,0,0,150,e_a);
            if(scheduler_halted || faults) $fatal(1,"FAIL: truncated window is a coverage fault, not halt");
        end
        $display("PASS: history_scheduler scenario%0d FP=%0d GDEPTH=%0d pixels=%0d results=%0d",
                 SCENARIO,FP,GDEPTH,checked_pixels,checked_results);
        test_done=1;
    end
    initial begin #4000000;if(!test_done) $fatal(1,"FAIL: scheduler timeout scenario%0d FP%0d pixels%0d results%0d pending%0d seal%0d ready%0b out%0b writer%0d scheduler%0d",SCENARIO,FP,checked_pixels,checked_results,pending_windows,sealed_time,frame_ready,out_valid,dut.store.writer.state,dut.scheduler.state);end
endmodule
module history_scheduler_tb;
    wire a,b,c,d;
    history_scheduler_case #(.FP(37),.GDEPTH(16),.SCENARIO(0)) normal(a);
    history_scheduler_case #(.FP(1),.GDEPTH(4),.SCENARIO(2)) truncated(b);
    history_scheduler_case #(.FP(37),.GDEPTH(4),.SCENARIO(3)) pressure(d);
    history_scheduler_case #(.FP(37),.GDEPTH(2),.SCENARIO(1)) evict(c);
    initial begin wait(a && b && c && d);$display("PASS: history_scheduler ALL");$finish;end
endmodule
