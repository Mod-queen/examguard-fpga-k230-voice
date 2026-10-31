`timescale 1ns/1ps
module camera_queued_evidence_tb;
    localparam FP=269,IW=$clog2(FP);
    reg clk=0,cap_clk=0,rst=1,cap_rst=1;
    always #5 clk=~clk;
    always #7 cap_clk=~cap_clk;
    reg frame_start=0,frame_end=0,in_valid=0,in_last=0;
    reg [IW-1:0] in_index=0;
    reg [15:0] in_data=0;
    reg [95:0] in_meta=0;
    wire pix_valid,pix_sof,pix_last,pix_ready,fifo_full;
    wire [15:0] pix_data;
    wire [95:0] pix_meta,out_meta,commit_meta;
    wire [1:0] banks_occupied;
    wire [31:0] frames_seen,frames_buffered,frames_sent,dropped_busy,dropped_invalid,dropped_disabled;
    camera_frame_guard #(.FRAME_PIXELS(FP)) guard (
        .clk(cap_clk),.rst(cap_rst),.enable(1'b1),.frame_start(frame_start),.frame_end(frame_end),
        .in_valid(in_valid),.in_index(in_index),.in_data(in_data),.in_last(in_last),.in_meta(in_meta),
        .out_valid(pix_valid),.out_sof(pix_sof),.out_last(pix_last),.out_data(pix_data),.out_meta(pix_meta),.out_ready(pix_ready),
        .banks_occupied(banks_occupied),.frames_seen(frames_seen),.frames_buffered(frames_buffered),.frames_sent(frames_sent),
        .dropped_busy(dropped_busy),.dropped_invalid(dropped_invalid),.dropped_disabled(dropped_disabled));
    reg request=0,out_ready=0,result_ready=0;
    reg [255:0] request_data=0;
    wire accepted,rejected,result_valid,result_ok,result_deferred,out_valid,out_sof,out_last,out_deferred,commit_valid;
    wire [255:0] out_event,result_event;
    wire [15:0] out_data;
    wire [2:0] commit_slot;
    wire [1:0] occupancy,high_water;
    wire [31:0] accepted_count,rejected_count,completed_count,result_frames;
    wire [31:0] frames_committed,frames_failed,windows_completed,read_errors,write_beats,read_beats;
    reg hold_b=0,inject_b=0,inject_r=0;
    `include "axi_frame_tb_wires.vh"
    ddr_evidence_queued #(.FRAME_PIXELS(FP),.EVENT_DEPTH(2),.RING_FRAMES(7),.FIFO_DEPTH(16),.BASE_ADDR(4080)) dut(.*);
    axi_frame_slave_model memory(.*);
    integer frames[0:15],uids[0:15],total=0,got=0,pixel=0,results=0,p,f;
    reg random_ready=0;
    reg [31:0] rng=32'h9876523;
    function [255:0] transaction;
        input integer uid;
        begin transaction={32'h1234,32'h5678,32'h9abc,64'(uid),64'h8765432100000200+uid,32'h00020350};end
    endfunction
    function [95:0] metadata;
        input integer f;
        begin metadata={32'(f),64'h8765432100000000+f*100};end
    endfunction
    always @(negedge clk) if(random_ready) begin
        rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};out_ready<=rng[0];
    end
    always @(posedge clk) if(!rst) begin
        if(out_valid && out_ready) begin
            if(got>=total || out_data!==((frames[got]*512+pixel)&65535) || out_meta!==metadata(frames[got]) ||
                out_event!==transaction(uids[got]) || out_deferred!==(uids[got]==2) ||
                out_sof!==(pixel==0) || out_last!==(pixel==FP-1))
                $fatal(1,"FAIL: guard/queue/DDR pixel+frame+identity got=%d pixel=%d",got,pixel);
            if(out_last) begin got=got+1;pixel=0;end else pixel=pixel+1;
        end
        if(result_valid && result_ready) begin
            if(!result_ok || result_event!==transaction(results+1) || result_frames!=4 || result_deferred!==(results==1))
                $fatal(1,"FAIL: guard queued event result");
            results=results+1;
        end
        if(commit_valid && commit_meta!==metadata(commit_meta[95:64]))
            $fatal(1,"FAIL: guard commit descriptor time mismatch");
    end
    task expect_frame;
        input integer n,uid;
        begin frames[total]=n;uids[total]=uid;total=total+1;end
    endtask
    task enqueue;
        input integer uid;
        begin
            @(negedge clk);request=1;request_data=transaction(uid);
            #1;if(!accepted) $fatal(1,"FAIL: unexpected rejection");
            @(negedge clk);request=0;
        end
    endtask
    // No sampling-domain ready: sources6..12 really run during lockout.
    task send_frame;
        input integer n,count;
        begin
            @(negedge cap_clk);frame_start=1;in_meta=metadata(n);
            @(negedge cap_clk);frame_start=0;
            for(p=0;p<count;p=p+1) begin
                in_valid=1;in_index=p;in_last=p==count-1;in_data=n*512+p;
                @(negedge cap_clk);
            end
            in_valid=0;in_last=0;in_meta=~metadata(n);
        end
    endtask
    initial begin
        repeat(8) @(negedge clk);rst=0;@(negedge cap_clk);cap_rst=0;
        send_frame(0,FP);wait(frames_committed==1);send_frame(1,FP);wait(frames_committed==2);
        for(f=0;f<4;f=f+1) expect_frame(f,1);
        enqueue(1);wait(dut.dispatcher.active);
        send_frame(2,FP);wait(frames_committed==3);send_frame(3,FP);wait(out_valid);
        // Identity2 queues DURING old readout, original source time stays intact.
        expect_frame(2,2);expect_frame(3,2);expect_frame(4,2);expect_frame(5,2);
        enqueue(2);
        for(f=4;f<13;f=f+1) send_frame(f,FP);
        if(dropped_busy!=7 || frames_committed!=4) $fatal(1,"FAIL: queued lockout frame drops");
        result_ready=1;random_ready=1;
        wait(results==2 && frames_committed==6);
        expect_frame(4,3);expect_frame(5,3);expect_frame(13,3);expect_frame(14,3);
        enqueue(3);wait(dut.dispatcher.active);
        send_frame(13,FP);wait(frames_committed==7);send_frame(14,FP);wait(results==3);
        send_frame(15,9);repeat(20) @(negedge clk);send_frame(16,FP);wait(frames_committed==9);
        if(got!=12 || pixel!=0 || frames_failed || read_errors || frames_seen!=17 || dropped_invalid!=1 ||
            accepted_count!=3 || completed_count!=3 || rejected_count!=0 || frames_sent!=9)
            $fatal(1,"FAIL: full camera queued conservation");
        $display("camera queued inputs=%0d commits=%0d whole_drops=%0d invalid=%0d event_results=%0d checked_pixels=%0d",
            frames_seen,frames_committed,dropped_busy,dropped_invalid,results,got*FP);
        $display("PASS: camera_queued_evidence all checks");$finish;
    end
    initial begin #10000000;$fatal(1,"FAIL: camera queued timeout");end
endmodule
