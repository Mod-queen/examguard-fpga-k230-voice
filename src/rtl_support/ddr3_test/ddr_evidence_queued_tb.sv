`timescale 1ns/1ps
module ddr_evidence_queued_tb;
    localparam FP=37;
    reg clk=0,cap_clk=0,rst=1,cap_rst=1;
    always #5 clk=~clk;
    always #7 cap_clk=~cap_clk;
    reg pix_valid=0,pix_sof=0,pix_last=0;
    reg [15:0] pix_data=0;
    reg [95:0] pix_meta=0;
    wire pix_ready,fifo_full,accepted,rejected;
    reg request=0;
    reg [255:0] request_data=0;
    wire [1:0] occupancy,high_water;
    wire [31:0] accepted_count,rejected_count,completed_count;
    wire out_valid,out_sof,out_last,out_deferred;
    wire [15:0] out_data;
    wire [95:0] out_meta,commit_meta;
    wire [255:0] out_event,result_event;
    reg out_ready=0,result_ready=0;
    wire result_valid,result_ok,result_deferred,commit_valid;
    wire [2:0] commit_slot;
    wire [31:0] result_frames,frames_committed,frames_failed,windows_completed,read_errors,write_beats,read_beats;
    reg hold_b=0,inject_b=0,inject_r=0;
    `include "axi_frame_tb_wires.vh"
    ddr_evidence_queued #(.FRAME_PIXELS(FP),.EVENT_DEPTH(2),.RING_FRAMES(7),.FIFO_DEPTH(16),.BASE_ADDR(4080)) dut(.*);
    axi_frame_slave_model memory(.*);
    integer expected[0:31];
    integer owners[0:31];
    integer total=0,got=0,pixel=0,p,n,results=0,commits=0;
    reg [255:0] expected_result[0:7];
    reg out_stall=0,result_stall=0;
    reg [369:0] held_out;
    reg [289:0] held_result;
    function [255:0] transaction;
        input integer uid;
        begin transaction={32'h12345678,32'h23456789,32'h3456789a,64'(uid),64'(uid*17),8'h02,8'h00,16'h0350};end
    endfunction
    function [95:0] metadata;
        input integer f;
        // >32bit timestamps to catch accidental truncation.
        begin metadata={32'(f),64'h1234567800000000+f*100};end
    endfunction
    always @(posedge clk) if(!rst) begin
        if(out_stall && (!out_valid || {out_event,out_meta,out_data,out_sof,out_last}!==held_out))
            $fatal(1,"FAIL: queued output identity/meta changed under stall");
        out_stall<=out_valid && !out_ready;
        held_out<={out_event,out_meta,out_data,out_sof,out_last};
        if(result_stall && (!result_valid || {result_event,result_ok,result_deferred,result_frames}!==held_result))
            $fatal(1,"FAIL: result overwritten under backpressure");
        result_stall<=result_valid && !result_ready;
        held_result<={result_event,result_ok,result_deferred,result_frames};
        if(out_valid && out_ready) begin
            if(got>=total || out_data!==((expected[got]*103+pixel)&65535) ||
                out_meta!==metadata(expected[got]) || out_event!==transaction(owners[got]) ||
                out_sof!==(pixel==0) || out_last!==(pixel==FP-1))
                $fatal(1,"FAIL: queued window data/metadata/identity frame=%d pixel=%d",got,pixel);
            if(out_last) begin got=got+1;pixel=0;end else pixel=pixel+1;
        end
        if(commit_valid) begin
            commits=commits+1;
            if(memory.responding || memory.writing || m_axi_bvalid || !dut.pipeline.slot_valid[commit_slot] ||
                commit_meta!==dut.pipeline.slot_meta[commit_slot]) $fatal(1,"FAIL: early/invalid descriptor commit");
        end
        if(result_valid && result_ready) begin
            if(result_event!==expected_result[results]) $fatal(1,"FAIL: reordered event result");
            results=results+1;
        end
    end
    task expect_frame;
        input integer f,uid;
        begin expected[total]=f;owners[total]=uid;total=total+1;end
    endtask
    task enqueue;
        input integer uid,okay;
        begin
            @(negedge clk);request=1;request_data=transaction(uid);
            #1;if(accepted!==okay || rejected===okay) $fatal(1,"FAIL: queue admission UID=%d",uid);
            @(negedge clk);request=0;request_data=~transaction(uid);
        end
    endtask
    task send_frame;
        input integer f;
        begin
            for(p=0;p<FP;p=p+1) begin
                @(negedge cap_clk);pix_valid=1;pix_sof=p==0;pix_last=p==FP-1;
                pix_data=f*103+p;
                // Only SOF metadata is authoritative; mutate every other beat.
                pix_meta=p==0 ? metadata(f) : ~metadata(f);
                @(posedge cap_clk);while(!pix_ready) @(posedge cap_clk);
                @(negedge cap_clk);pix_valid=0;
            end
            pix_sof=0;pix_last=0;
        end
    endtask
    task good;
        input integer f;
        integer target;
        begin target=frames_committed+1;send_frame(f);wait(frames_committed==target);@(negedge clk);end
    endtask
    task result_check;
        input integer uid,okay,defer,count;
        begin
            wait(result_valid);#1;
            if(result_event!==transaction(uid) || result_ok!==okay || result_deferred!==defer || result_frames!==count)
                $fatal(1,"FAIL: result identity/status UID=%d",uid);
        end
    endtask
    initial begin
        for(n=0;n<6;n=n+1) expected_result[n]=transaction(n+1);
        repeat(8) @(negedge clk);rst=0;@(negedge cap_clk);cap_rst=0;
        good(10);good(30);
        expect_frame(10,1);expect_frame(30,1);expect_frame(50,1);expect_frame(70,1);
        enqueue(1,1);wait(dut.dispatcher.active);good(50);good(70);
        wait(out_valid);enqueue(2,1);enqueue(3,1);enqueue(4,0);enqueue(5,0);
        out_ready=1;result_check(1,1,0,4);
        repeat(40) @(negedge clk);
        if(accepted_count!=3 || completed_count!=1 || occupancy!=2 || dut.dispatcher.active)
            $fatal(1,"FAIL: result backpressure failed to block dispatch");
        enqueue(6,0);
        expect_frame(50,2);expect_frame(70,2);expect_frame(90,2);expect_frame(110,2);
        result_ready=1;wait(dut.dispatcher.active && out_event==transaction(2));
        @(negedge clk);result_ready=0;
        good(90);good(110);result_check(2,1,1,4);
        expect_frame(90,3);expect_frame(110,3);expect_frame(130,3);expect_frame(150,3);
        @(negedge clk);result_ready=1;wait(dut.dispatcher.active && out_event==transaction(3));
        @(negedge clk);result_ready=0;
        good(130);good(150);result_check(3,1,1,4);
        @(negedge clk);result_ready=1;wait(!result_valid);@(negedge clk);result_ready=0;
        // Failed B publishes a failed EVENT result but no valid frame descriptor.
        enqueue(4,1);wait(dut.dispatcher.active);inject_b=1;send_frame(170);
        result_check(4,0,0,4);inject_b=0;
        if(frames_failed!=1 || commits!=8) $fatal(1,"FAIL: failed B published descriptor");
        @(negedge clk);result_ready=1;wait(!result_valid);@(negedge clk);result_ready=0;
        expect_frame(190,5);expect_frame(210,5);
        enqueue(5,1);wait(dut.dispatcher.active);good(190);good(210);result_check(5,1,0,2);
        @(negedge clk);result_ready=1;wait(!result_valid);@(negedge clk);
        if(accepted_count!=5 || rejected_count!=3 || completed_count!=5 || results!=5 ||
            got!=14 || commits!=10 || frames_committed!=10 || high_water!=2)
            $fatal(1,"FAIL: queued integration conservation");
        // R error must keep event identity while explicitly invalidating its
        // completed window (pixel bytes alone cannot establish success).
        expect_frame(190,6);expect_frame(210,6);expect_frame(230,6);expect_frame(250,6);
        result_ready=0;inject_r=1;
        enqueue(6,1);wait(dut.dispatcher.active);good(230);good(250);result_check(6,0,0,4);
        inject_r=0;
        if(read_errors!=4) $fatal(1,"FAIL: queued read error accounting");
        @(negedge clk);result_ready=1;wait(!result_valid);@(negedge clk);
        // Reset cancels active+queued identity and all descriptor validity.
        enqueue(7,1);wait(dut.dispatcher.active);enqueue(8,1);
        @(negedge clk);rst=1;cap_rst=1;
        repeat(6) @(negedge clk);rst=0;@(negedge cap_clk);cap_rst=0;
        repeat(20) @(negedge clk);
        if(result_valid || dut.dispatcher.active || occupancy || frames_committed || dut.pipeline.slot_valid)
            $fatal(1,"FAIL: reset leaked old identity/descriptor");
        $display("queued AXI checked_frames=%0d checked_pixels=%0d results=%0d accepted=6 rejected=3 incl failed-B/read-error",got,got*FP,results);
        $display("PASS: ddr_evidence_queued all checks");$finish;
    end
    initial begin #10000000;$fatal(1,"FAIL: queued AXI timeout");end
endmodule
