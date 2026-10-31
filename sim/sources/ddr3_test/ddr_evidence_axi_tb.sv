`timescale 1ns/1ps
module ddr_evidence_axi_tb;
    localparam FP=269;
    reg clk=0, cap_clk=0, rst=1, cap_rst=1;
    always #5 clk=~clk;
    always #7 cap_clk=~cap_clk;
    reg pix_valid=0, pix_sof=0, pix_last=0;
    reg [15:0] pix_data=0;
    wire pix_ready, fifo_full;
    reg event_pulse=0, out_ready=0;
    wire out_valid, out_sof, out_last, busy, pending, overrun, window_done, window_ok;
    wire [15:0] out_data;
    wire [31:0] frames_committed, frames_failed, windows_completed, read_errors;
    wire [31:0] rejected_events, write_beats, read_beats;
    wire event_ready, window_started, commit_valid;
    wire [31:0] window_frame_count;
    wire [2:0] commit_slot;
    wire [95:0] pix_meta = {32'(pix_data/512),64'(pix_data/512*100)};
    wire [95:0] out_meta, commit_meta;
    reg hold_b=0, inject_b=0, inject_r=0;
    `include "axi_frame_tb_wires.vh"
    ddr_evidence_axi #(.ENABLE_META(1),.FRAME_PIXELS(FP),.RING_FRAMES(7),.FIFO_DEPTH(16),.BASE_ADDR(4080)) dut (.*);
    axi_frame_slave_model memory (.*);
    reg [31:0] rng=32'h31415926;
    integer expected [0:31];
    integer exp_count=0, got_frames=0, got_pixels=0, full_cycles=0;
    integer p, f, good_windows=0, bad_windows=0, before_count;
    always @(negedge clk) begin
        rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        out_ready<=rng[4];
    end
    always @(posedge cap_clk) if (!cap_rst && fifo_full) full_cycles=full_cycles+1;
    always @(posedge clk) if (!rst) begin
        if(out_valid && out_ready) begin
            if(got_frames>=exp_count || out_data !== ((expected[got_frames]*512+got_pixels)&16'hffff) ||
                out_sof!=(got_pixels==0) || out_last!=(got_pixels==FP-1) ||
                out_meta!=={32'(expected[got_frames]),64'(expected[got_frames]*100)})
                $fatal(1,"FAIL: window pixel frame=%d pixel=%d data=%h expect frame=%d",got_frames,got_pixels,out_data,expected[got_frames]);
            if(out_last) begin got_frames=got_frames+1; got_pixels=0; end
            else got_pixels=got_pixels+1;
        end
        if(m_axi_arvalid && m_axi_arready &&
            (memory.writing || memory.responding || m_axi_bvalid || dut.wr_busy))
            $fatal(1,"FAIL: read before successful write response");
        if(commit_valid && (commit_meta!==dut.slot_meta[commit_slot] || !dut.slot_valid[commit_slot]))
            $fatal(1,"FAIL: committed slot descriptor");
        if(window_done) begin
            if(window_ok) good_windows=good_windows+1; else bad_windows=bad_windows+1;
        end
    end
    task expect_frame;
        input integer n;
        begin expected[exp_count]=n; exp_count=exp_count+1; end
    endtask
    task pulse_event;
        begin
            @(negedge clk); event_pulse=1;
            @(negedge clk); event_pulse=0;
        end
    endtask
    task send_frame;
        input integer n;
        input integer count;
        input integer last_flag;
        begin
            for(p=0;p<count;p=p+1) begin
                @(negedge cap_clk);
                pix_valid=1; pix_sof=p==0; pix_last=last_flag && p==count-1;
                pix_data=n*512+p;
                @(posedge cap_clk); while(!pix_ready) @(posedge cap_clk);
                @(negedge cap_clk); pix_valid=0;
            end
            pix_sof=0; pix_last=0;
        end
    endtask
    task send_good;
        input integer n;
        integer target;
        begin
            target=frames_committed+1;
            send_frame(n,FP,1); wait(frames_committed==target); @(negedge clk);
        end
    endtask
    initial begin
        repeat(8) @(negedge clk); rst=0;
        @(negedge cap_clk); cap_rst=0;
        // Startup shortage: PRE=2 but no committed history. Only post frames.
        expect_frame(0); expect_frame(1);
        pulse_event(); send_good(0); send_good(1);
        wait(windows_completed==1 && !busy); @(negedge clk);
        // >2 complete wraps. Event MID frame, current frame is first POST.
        for(f=2;f<20;f=f+1) send_good(f);
        expect_frame(18); expect_frame(19); expect_frame(20); expect_frame(21);
        fork
            send_good(20);
            begin wait(dut.capture_pixel==100); pulse_event(); end
        join
        // Withhold FINAL B of last post frame (not the first burst's B).
        fork
            send_good(21);
            begin
                wait(dut.dma.wp==FP && dut.dma.ws==2);
                @(negedge clk); hold_b=1;
                before_count=frames_committed;
                repeat(100) @(posedge clk);
                if(frames_committed!=before_count || windows_completed!=1 || m_axi_arvalid)
                    $fatal(1,"FAIL: frame committed/read before final B");
                @(negedge clk); hold_b=0;
            end
        join
        wait(dut.reading);
        pulse_event(); pulse_event(); // one queued, one explicitly rejected
        expect_frame(20); expect_frame(21); expect_frame(22); expect_frame(23);
        send_good(22); send_good(23);
        wait(windows_completed==3 && !busy); @(negedge clk);
        if(!overrun || rejected_events!=1) $fatal(1,"FAIL: pending/reject accounting");
        // Short frame and missing LAST are never committed; restart history.
        send_frame(24,7,1); wait(frames_failed==1); @(negedge clk);
        send_frame(25,FP,0); wait(frames_failed==2); @(negedge clk);
        // B error aborts capture window, then a fresh good frame can succeed.
        inject_b=1; pulse_event(); send_frame(26,FP,1);
        wait(frames_failed==3 && !busy); @(negedge clk); inject_b=0;
        send_good(27);
        expect_frame(27); expect_frame(28); expect_frame(29);
        inject_r=1; pulse_event(); send_good(28); send_good(29);
        wait(windows_completed==4 && !busy); repeat(2) @(negedge clk); inject_r=0;
        if(read_errors!=3 || good_windows!=3 || bad_windows!=2)
            $fatal(1,"FAIL: error/window accounting good=%d bad=%d r=%d",good_windows,bad_windows,read_errors);
        if(got_frames!=exp_count || got_pixels!=0 || full_cycles==0)
            $fatal(1,"FAIL: missing data or FIFO full coverage");
        // Reset during a pending AXI response; old DDR content must not become
        // valid history. Reset the slave AND both FIFO domains together.
        fork
            send_frame(30,FP,1);
            begin wait(dut.dma.wp==FP && dut.dma.ws==4); @(negedge clk); hold_b=1; end
        join
        @(negedge clk); rst=1; cap_rst=1;
        repeat(8) @(negedge clk); rst=0; hold_b=0;
        @(negedge cap_clk); cap_rst=0;
        expect_frame(31); expect_frame(32);
        pulse_event(); send_good(31); send_good(32);
        wait(windows_completed==1 && !busy); @(negedge clk);
        if(frames_committed!=2 || frames_failed!=0 || got_frames!=exp_count)
            $fatal(1,"FAIL: reset validity");
        // An event coincident with the failed frame's completion must survive
        // as pending; it must not be stranded with busy=0.
        expect_frame(33); expect_frame(34);
        pulse_event();
        fork
            send_frame(99,7,1);
            begin
                wait(dut.fail_fire);
                @(negedge clk); event_pulse=1;
                @(negedge clk); event_pulse=0;
            end
        join
        send_good(33); send_good(34);
        wait(windows_completed==2 && !busy); repeat(2) @(negedge clk);
        if(pending || frames_failed!=1 || got_frames!=exp_count)
            $fatal(1,"FAIL: failure-coincident pending event");
        $display("frames checked=%0d full cycles=%0d last write/read beats=%0d/%0d",got_frames,full_cycles,write_beats,read_beats);
        $display("PASS: ddr_evidence_axi all checks"); $finish;
    end
    initial begin #20000000; $fatal(1,"FAIL: evidence AXI timeout"); end
endmodule
