`timescale 1ns/1ps

// Non-stallable numbered sampling stream -> whole-frame guard -> async FIFO ->
// actual frame DMA/ring -> independent byte-addressed AXI memory -> windows.
module camera_evidence_axi_tb;
    localparam FP=269, IW=$clog2(FP);
    reg clk=0, cap_clk=0, rst=1, cap_rst=1;
    always #5 clk=~clk;
    always #7 cap_clk=~cap_clk;
    reg frame_start=0, frame_end=0, in_valid=0, in_last=0;
    reg [IW-1:0] in_index=0;
    reg [15:0] in_data=0;
    reg [95:0] in_meta=0;
    wire pix_valid, pix_sof, pix_last, pix_ready, fifo_full;
    wire [15:0] pix_data;
    wire [95:0] capture_meta;
    wire [1:0] banks_occupied;
    wire [31:0] frames_seen, frames_buffered, frames_sent;
    wire [31:0] dropped_busy, dropped_invalid, dropped_disabled;
    camera_frame_guard #(.FRAME_PIXELS(FP)) guard (
        .clk(cap_clk),.rst(cap_rst),.enable(1'b1),
        .frame_start(frame_start),.frame_end(frame_end),.in_valid(in_valid),
        .in_index(in_index),.in_data(in_data),.in_last(in_last),.in_meta(in_meta),
        .out_valid(pix_valid),.out_data(pix_data),.out_sof(pix_sof),.out_last(pix_last),
        .out_meta(capture_meta),.out_ready(pix_ready),.banks_occupied(banks_occupied),
        .frames_seen(frames_seen),.frames_buffered(frames_buffered),.frames_sent(frames_sent),
        .dropped_busy(dropped_busy),.dropped_invalid(dropped_invalid),.dropped_disabled(dropped_disabled));
    reg event_pulse=0, out_ready=0;
    wire out_valid, out_sof, out_last, busy, pending, overrun, window_done, window_ok;
    wire [15:0] out_data;
    wire [31:0] frames_committed, frames_failed, windows_completed, read_errors;
    wire [31:0] rejected_events, write_beats, read_beats;
    wire [95:0] pix_meta = capture_meta;
    wire [95:0] out_meta, commit_meta;
    wire event_ready, window_started, commit_valid;
    wire [31:0] window_frame_count;
    wire [2:0] commit_slot;
    reg hold_b=0, inject_b=0, inject_r=0;
    `include "axi_frame_tb_wires.vh"
    ddr_evidence_axi #(.ENABLE_META(1),.FRAME_PIXELS(FP),.FIFO_DEPTH(16),.RING_FRAMES(7),.BASE_ADDR(4080)) dut (.*);
    axi_frame_slave_model memory (.*);
    integer expected [0:15];
    integer got_frame=0, got_pixel=0, target_frames=0, cap_pixel=0;
    integer cap_frame=0, p, f;
    reg random_ready=0;
    reg [31:0] rng=32'h12534876;
    always @(negedge clk) if(random_ready) begin
        rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]}; out_ready<=rng[3];
    end
    always @(posedge cap_clk) if(!cap_rst && pix_valid && pix_ready) begin
        if(pix_sof) cap_frame=capture_meta[95:64];
        if(pix_data!==((cap_frame*512+cap_pixel)&16'hffff) ||
            pix_sof!==(cap_pixel==0) || pix_last!==(cap_pixel==FP-1))
            $fatal(1,"FAIL: guard-to-FIFO metadata/frame integrity");
        if(pix_last) cap_pixel=0; else cap_pixel=cap_pixel+1;
    end
    always @(posedge clk) if(!rst) begin
        if(window_done && !window_ok) $fatal(1,"FAIL: invalid camera evidence window");
        if(out_valid && out_ready) begin
            if(got_frame>=target_frames || out_data!==((expected[got_frame]*512+got_pixel)&16'hffff) ||
                out_sof!==(got_pixel==0) || out_last!==(got_pixel==FP-1) ||
                out_meta!=={32'(expected[got_frame]),64'h8765432100000000+expected[got_frame]*100})
                $fatal(1,"FAIL: camera DDR window got frame=%d pixel=%d data=%h",got_frame,got_pixel,out_data);
            if(out_last) begin got_frame=got_frame+1; got_pixel=0; end
            else got_pixel=got_pixel+1;
        end
    end
    task expect_frame;
        input integer n;
        begin expected[target_frames]=n; target_frames=target_frames+1; end
    endtask
    task event_now;
        begin @(negedge clk); event_pulse=1; @(negedge clk); event_pulse=0; end
    endtask
    // Producer NEVER looks at pix_ready (unlike the earlier stallable probe).
    task send_frame;
        input integer n, count;
        begin
            @(negedge cap_clk); frame_start=1; in_meta={32'(n),64'h8765432100000000+n*100};
            @(negedge cap_clk); frame_start=0;
            for(p=0;p<count;p=p+1) begin
                in_valid=1; in_index=p; in_last=p==count-1; in_data=n*512+p;
                @(negedge cap_clk);
            end
            in_valid=0; in_last=0;
        end
    endtask
    initial begin
        repeat(8) @(negedge clk); rst=0;
        @(negedge cap_clk); cap_rst=0;
        send_frame(0,FP); wait(frames_committed==1);
        send_frame(1,FP); wait(frames_committed==2);
        for(f=0;f<4;f=f+1) expect_frame(f);
        event_now();
        send_frame(2,FP); wait(frames_committed==3);
        send_frame(3,FP); wait(dut.reading);
        // Locked readout and small FIFO stop DDR ingress for many camera frames.
        // Two banks retain frames4/5; every later frame must be wholly dropped.
        for(f=4;f<13;f=f+1) send_frame(f,FP);
        if(frames_committed!=4 || dropped_busy!=7 || banks_occupied!=2)
            $fatal(1,"FAIL: locked-window pressure count commit=%d drops=%d banks=%d",frames_committed,dropped_busy,banks_occupied);
        random_ready=1;
        wait(windows_completed==1 && frames_committed==6 && !busy);
        // Retained 4/5 become the PRE history, not the discarded frame tails.
        expect_frame(4); expect_frame(5); expect_frame(13); expect_frame(14);
        event_now(); send_frame(13,FP); wait(frames_committed==7);
        send_frame(14,FP); wait(windows_completed==2 && !busy);
        send_frame(15,9); // early LAST rejected BEFORE the DMA can see it
        repeat(15) @(negedge clk);
        if(dropped_invalid!=1 || frames_failed!=0 || frames_committed!=8 || read_errors!=0)
            $fatal(1,"FAIL: malformed frame escaped guard");
        send_frame(16,FP); wait(frames_committed==9);
        if(got_frame!=8 || got_pixel!=0 || frames_sent!=9 || dropped_busy!=7)
            $fatal(1,"FAIL: final camera pipeline accounting");
        $display("camera input=%0d buffered=%0d sent=%0d busy_drops=%0d invalid=%0d DDRcommits=%0d windows=%0d checked_pixels=%0d",
            frames_seen,frames_buffered,frames_sent,dropped_busy,dropped_invalid,frames_committed,windows_completed,got_frame*FP);
        $display("PASS: camera_evidence_axi all checks"); $finish;
    end
    initial begin #10000000; $fatal(1,"FAIL: camera evidence timeout"); end
endmodule
