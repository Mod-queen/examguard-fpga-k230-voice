`timescale 1ns/1ps
module history_frame_writer_case #(parameter FP=37)(output reg done=0);
    localparam BASE=4080;
    reg clk=0,rst=1;
    always #5 clk=~clk;
    reg command_valid=0,command_fence=0;
    reg [95:0] command_meta=0;
    wire command_ready,pixel_ready;
    reg pixel_valid=0,pixel_last=0;
    reg [15:0] pixel_data=0;
    wire reserve_valid,reserve_ready,grant_valid,grant_ready,grant_ok;
    wire grant_slot,finish_slot;
    wire [31:0] grant_token,finish_token;
    wire finish_valid,finish_ready,finish_ok,seal_valid,seal_ready;
    wire [95:0] finish_meta;
    wire [63:0] seal_time;
    wire wr_start,wr_busy,wr_done,wr_ok,dma_valid,dma_last,dma_ready;
    wire [29:0] wr_base;
    wire [15:0] dma_data;
    wire result_valid;
    reg result_ready=0;
    wire [95:0] result_meta;
    wire [2:0] result_code;
    wire fence_done,fence_ok,writer_fault;
    wire [31:0] frames_committed,frames_dropped;
    history_frame_writer #(.FRAME_PIXELS(FP),.SLOTS(1),.BASE_ADDR(BASE)) writer(.protocol_fault(writer_fault),.*);
    reg request_valid=0,release_valid=0;
    wire request_ready,release_ready,accepted,accepted_window;
    reg [255:0] request_event=0;
    wire query_active,query_closed,query_truncated,query_capture_error,query_slots,protected_slots;
    wire [255:0] query_event;
    wire slot_valid,directory_fault,token_exhausted;
    wire [95:0] slot_meta;
    wire [31:0] reserve_rejected,write_failed;
    // Interpose deliberate directory backpressure without changing ownership.
    reg allow_finish=1,allow_reserve=1,allow_seal=1;
    wire dir_finish_ready,dir_reserve_ready,dir_seal_ready;
    assign finish_ready=dir_finish_ready && allow_finish;
    assign reserve_ready=dir_reserve_ready && allow_reserve;
    assign seal_ready=dir_seal_ready && allow_seal;
    history_reference_directory #(.SLOTS(1),.WINDOWS(1),.PRE_MS(100),.POST_MS(100)) directory(
        .finish_valid(finish_valid && allow_finish),.finish_ready(dir_finish_ready),
        .reserve_valid(reserve_valid && allow_reserve),.reserve_ready(dir_reserve_ready),
        .seal_valid(seal_valid && allow_seal),.seal_ready(dir_seal_ready),
        .release_window(1'b0),.query_window(1'b0),.query_slot(1'b0),.protocol_fault(directory_fault),
        .accepted_token(),.window_token_exhausted(),.release_token(32'd0),.release_done(),.release_ok(),.query_token(),.writer_pending_o(),.active_mask(),.closed_mask(),.*);
    `include "axi_frame_tb_wires.vh"
    reg hold_b=0,inject_b=0,inject_r=0,rd_start=0,out_ready=0;
    reg [29:0] rd_base=BASE;
    wire rd_busy,rd_done,rd_ok,out_valid,out_sof,out_last;
    wire [15:0] out_data;
    wire [31:0] write_beats,read_beats;
    ddr3_axi_frame_dma #(.FRAME_PIXELS(FP),.BURST(1)) dma(
        .in_valid(dma_valid),.in_data(dma_data),.in_last(dma_last),.in_ready(dma_ready),.*);
    axi_frame_slave_model memory(.*);
    integer starts=0,finishes=0,seals=0;
    always @(posedge clk) if(!rst) begin
        if(wr_start) starts=starts+1;
        if(finish_valid && finish_ready) finishes=finishes+1;
        if(seal_valid && seal_ready) begin
            if(wr_busy || directory.writer_pending || finish_valid) $fatal(1,"FAIL: seal overtook in-flight writer");
            seals=seals+1;
        end
        if(m_axi_awvalid && m_axi_awready && protected_slots) $fatal(1,"FAIL: AW overwritten protected slot");
    end
    task automatic command(input [63:0] stamp,input fence);
        begin
            @(negedge clk);command_valid=1;command_fence=fence;command_meta={32'h89abcdef,stamp};
            @(posedge clk);while(!command_ready) @(posedge clk);
            @(negedge clk);command_valid=0;
        end
    endtask
    task automatic pixels(input integer count,input integer base);
        integer p;
        begin
            for(p=0;p<count;p=p+1) begin
                @(negedge clk);pixel_valid=1;pixel_data=base+p;pixel_last=p==count-1;
                @(posedge clk);while(!pixel_ready) @(posedge clk);
                @(negedge clk);pixel_valid=0;pixel_last=0;
                repeat(p%3) @(negedge clk);
            end
        end
    endtask
    task automatic result(input [2:0] code,input [63:0] stamp);
        reg [95:0] saved;
        begin
            wait(result_valid);#1;saved=result_meta;
            repeat(20) begin
                @(negedge clk);
                if(!result_valid || command_ready || result_code!=code || result_meta!==saved || saved!=={32'h89abcdef,stamp})
                    $fatal(1,"FAIL: held result code=%0d expected%0d stamp=%0d",result_code,code,stamp);
            end
            result_ready=1;@(negedge clk);result_ready=0;
        end
    endtask
    task automatic readback(input integer base);
        integer p;
        begin
            @(negedge clk);rd_start=1;@(negedge clk);rd_start=0;
            for(p=0;p<FP;p=p+1) begin
                repeat(p%4) @(negedge clk);out_ready=1;
                @(posedge clk);while(!out_valid) @(posedge clk);
                if(out_data!=base+p || out_sof!=(p==0) || out_last!=(p==FP-1)) $fatal(1,"FAIL: actual DMA pixel mismatch");
                @(negedge clk);out_ready=0;
            end
            if(!rd_done) wait(rd_done);
            #1;if(!rd_ok) $fatal(1,"FAIL: actual DMA read verdict");
        end
    endtask
    task automatic reset_all;
        begin
            @(negedge clk);rst=1;command_valid=0;pixel_valid=0;pixel_last=0;
            result_ready=0;hold_b=0;inject_b=0;request_valid=0;release_valid=0;
            allow_finish=1;allow_reserve=1;allow_seal=1;
            repeat(4) @(negedge clk);rst=0;
            starts=0;finishes=0;seals=0;
        end
    endtask
    integer before_starts,before_aw;
    initial begin
        reset_all();allow_reserve=0;command(100,0);
        repeat(15) @(negedge clk);
        if(!reserve_valid || wr_start || pixel_ready) $fatal(1,"FAIL: reserve backpressure");
        allow_reserve=1;allow_finish=0;hold_b=1;
        fork
            pixels(FP,1000);
            begin
                wait(m_axi_bready);repeat(20) @(negedge clk);
                if(slot_valid || finish_valid || result_valid) $fatal(1,"FAIL: published before B");
                hold_b=0;
            end
        join
        wait(finish_valid);repeat(20) @(negedge clk);
        if(slot_valid || result_valid || !finish_ok || finish_meta!=={32'h89abcdef,64'd100}) $fatal(1,"FAIL: finish backpressure");
        allow_finish=1;result(0,100);
        if(!slot_valid || slot_meta!=={32'h89abcdef,64'd100} || frames_committed!=1 || finishes!=1) $fatal(1,"FAIL: initial publication");
        readback(1000);
        @(negedge clk);request_event={32'd1,32'd5,32'd3,64'd1,64'd150,8'd1,8'd0,16'h3750};request_valid=1;
        @(posedge clk);while(!request_ready) @(posedge clk);
        @(negedge clk);request_valid=0;repeat(5) @(negedge clk);
        if(!protected_slots || query_closed) $fatal(1,"FAIL: window protection");
        before_starts=starts;before_aw=memory.aw_count;
        command(200,0);pixels(FP,2000);result(1,200);
        if(starts!=before_starts || memory.aw_count!=before_aw || !slot_valid || frames_dropped!=1)
            $fatal(1,"FAIL: capacity rejection touched DMA/old frame");
        readback(1000);
        allow_seal=0;command(250,1);repeat(20) @(negedge clk);
        if(!seal_valid || seal_time!=250 || query_closed) $fatal(1,"FAIL: held seal");
        allow_seal=1;wait(fence_done);#1;
        if(!fence_ok || !query_closed || seals!=1) $fatal(1,"FAIL: ordered fence");
        @(negedge clk);release_valid=1;@(posedge clk);while(!release_ready) @(posedge clk);
        @(negedge clk);release_valid=0;
        // Stale and duplicate commands drain without reserve or DMA.
        command(250,0);pixels(FP,2500);result(4,250);
        if(starts!=before_starts || directory_fault) $fatal(1,"FAIL: old timestamp reached directory");
        inject_b=1;command(300,0);pixels(FP,3000);result(2,300);inject_b=0;
        if(slot_valid || write_failed!=1) $fatal(1,"FAIL: failed B publication");
        if(FP>1) begin
            command(350,0);pixels(5,3500);result(3,350);
            if(slot_valid || write_failed!=2) $fatal(1,"FAIL: short frame publication");
        end
        command(400,0);pixels(FP+5,4000);result(3,400);
        if(slot_valid || write_failed!=(FP>1?3:2)) $fatal(1,"FAIL: long frame publication");
        command(450,0);pixels(FP,4500);result(0,450);readback(4500);
        command(450,0);pixels(FP,4600);result(4,450);readback(4500);
        command(449,1);#1;
        if(!fence_done || fence_ok || seals!=1) $fatal(1,"FAIL: backward fence accepted");
        command(500,1);wait(fence_done);#1;if(!fence_ok) $fatal(1,"FAIL: good later fence");
        // Common reset with old B outstanding; no finish/result reappears.
        hold_b=1;command(550,0);
        fork
            pixels(FP>8?8:FP,5500);
            begin wait(m_axi_bready);end
        join
        reset_all();repeat(40) @(negedge clk);
        if(result_valid || finish_valid || slot_valid || wr_busy) $fatal(1,"FAIL: old epoch completion leaked");
        command(100,0);pixels(FP,6000);result(0,100);readback(6000);
        if(directory_fault || writer_fault) $fatal(1,"FAIL: new epoch poisoned");
        // A queued fence is held while the preceding frame is stopped at B.
        // It cannot overtake that frame even when source command_valid is high.
        hold_b=1;command(200,0);
        fork
            pixels(FP,6200);
            begin
                wait(m_axi_bready);
                @(negedge clk);command_valid=1;command_fence=1;command_meta={32'd0,64'd200};
                repeat(30) begin
                    @(negedge clk);
                    if(command_ready || seal_valid || slot_valid) $fatal(1,"FAIL: pending fence bypassed B");
                end
                hold_b=0;
            end
        join
        result(0,200);
        @(posedge clk);while(!command_ready) @(posedge clk);
        @(negedge clk);command_valid=0;wait(fence_done);#1;
        if(!fence_ok || directory_fault) $fatal(1,"FAIL: queued fence not delivered");
        reset_all();
        // Missing LAST cannot be reinterpreted as a new frame or successful
        // fence. Wait for resynchronizing LAST, or a common epoch cancellation.
        command(100,0);
        for(before_aw=0;before_aw<FP;before_aw=before_aw+1) begin
            @(negedge clk);pixel_valid=1;pixel_last=0;pixel_data=7000+before_aw;
            @(posedge clk);while(!pixel_ready) @(posedge clk);
            @(negedge clk);pixel_valid=0;
        end
        wait(writer.state==6);repeat(40) @(negedge clk);
        if(result_valid || finish_valid || command_ready || slot_valid) $fatal(1,"FAIL: missing LAST fabricated completion");
        reset_all();command(100,0);pixels(FP,7100);result(0,100);readback(7100);
        // Equal fences are idempotent; MAX time cannot wrap into a new epoch.
        command(64'hffffffffffffffff,1);wait(fence_done);#1;if(!fence_ok) $fatal(1,"FAIL: MAX fence");
        command(64'hffffffffffffffff,1);wait(fence_done);#1;if(!fence_ok) $fatal(1,"FAIL: duplicate fence");
        before_starts=starts;
        command(0,0);pixels(FP,7200);result(4,0);
        if(starts!=before_starts) $fatal(1,"FAIL: time wrapped after MAX fence");
        $display("PASS: history_frame_writer FP=%0d actualDMA/directory/Bdelay/stalls/capacity/shape/time/queued-fence/MAX/reset",FP);
        done=1;
    end
    initial begin #2000000;$fatal(1,"FAIL: writer timeout state=%0d DMA=%0d",writer.state,dma.ws);end
endmodule
module history_frame_writer_tb;
    wire a,b;
    history_frame_writer_case #(.FP(1)) one(a);
    history_frame_writer_case #(.FP(37)) tail(b);
    initial begin wait(a && b);$display("PASS: history_frame_writer ALL");$finish;end
endmodule
