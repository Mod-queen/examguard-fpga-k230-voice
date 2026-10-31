`timescale 1ns/1ps

// Self-checking TB for the DDR evidence ring: a producer streams numbered
// frames, an event is pulsed during frame 5, and the locked readout must be
// exactly frames [3,4,5,6] (PRE=2 before, POST=2 from the event frame), in
// order, with no corruption.
module ddr_evidence_ring_tb;
    localparam integer FP = 4, PRE = 2, POST = 2, RING = 8;
    localparam integer TOTAL_FRAMES = 12;
    localparam integer EVENT_FRAME = 5;

    reg clk = 0, rst = 1;
    reg pix_valid = 0;
    wire pix_last;
    wire [15:0] pix_data;
    wire pix_ready;
    wire wr_en, rd_en, rd_valid;
    wire [4:0] wr_addr, rd_addr;
    wire [15:0] wr_data, rd_data;
    reg ev1 = 0, ev2 = 0;
    wire event_pulse = ev1 | ev2;
    wire out_valid, out_sof, out_last;
    wire [15:0] out_data;
    wire window_ready, busy, overrun, pending_flag;

    integer errors = 0;

    ddr_evidence_ring #(.FRAME_PIXELS(FP), .PRE_FRAMES(PRE), .POST_FRAMES(POST),
                        .RING_FRAMES(RING), .PIX_WIDTH(16)) dut (
        .clk(clk), .rst(rst), .start(1'b1),
        .pix_valid(pix_valid), .pix_data(pix_data), .pix_last(pix_last), .pix_ready(pix_ready),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data), .rd_valid(rd_valid),
        .event_pulse(event_pulse),
        .out_valid(out_valid), .out_data(out_data), .out_sof(out_sof), .out_last(out_last),
        .out_ready(1'b1),
        .window_ready(window_ready), .busy(busy), .overrun(overrun), .pending(pending_flag));

    always #5 clk = ~clk;

    // ---- Behavioral word memory ----
    reg [15:0] mem [0:RING*FP-1];
    always @(posedge clk) if (wr_en) mem[wr_addr] <= wr_data;
    reg rd_valid_r = 0; reg [15:0] rd_data_r = 0;
    always @(posedge clk) begin rd_valid_r <= rd_en; rd_data_r <= mem[rd_addr]; end
    assign rd_valid = rd_valid_r;
    assign rd_data  = rd_data_r;

    // ---- Producer: frames 0..TOTAL_FRAMES-1, pixel p of frame f = f*1000+p ----
    reg [15:0] frame_idx = 0, pix_idx = 0;
    reg        sending = 1;
    assign pix_data = frame_idx * 16'd1000 + pix_idx;
    assign pix_last = (pix_idx == FP-1);
    always @(posedge clk) begin
        if (rst) begin
            pix_valid <= 1'b0; frame_idx <= 0; pix_idx <= 0; sending <= 1'b1;
        end else begin
            pix_valid <= sending && pix_ready;
            if (pix_valid && pix_ready) begin
                if (pix_idx == FP-1) begin
                    pix_idx   <= 0;
                    frame_idx <= frame_idx + 1;
                    if (frame_idx + 1 >= TOTAL_FRAMES) sending <= 1'b0;
                end else pix_idx <= pix_idx + 1;
            end
        end
    end

    // Pulse event 1 while frame EVENT_FRAME's first pixel is accepted.
    always @(posedge clk) begin
        ev1 <= 1'b0;
        if (!rst && pix_valid && pix_ready && frame_idx == EVENT_FRAME && pix_idx == 0)
            ev1 <= 1'b1;
    end

    // Pulse event 2 while the first window is being read out (busy-time event),
    // to exercise the pending/queue path.
    reg sent2 = 0;
    always @(posedge clk) begin
        ev2 <= 1'b0;
        if (!rst && !sent2 && window_ready) begin
            ev2 <= 1'b1; sent2 <= 1'b1;
        end
    end

    // ---- Consumer: capture the locked window (out_ready always 1) ----
    integer got = 0;
    reg [15:0] cap [0:RING*FP-1];
    always @(posedge clk) begin
        if (!rst && out_valid) begin
            if (got < RING*FP) cap[got] = out_data;
            got = got + 1;
        end
    end

    // Expected pixel for window position i (0-based over PRE+POST frames):
    // frame = EVENT_FRAME - PRE + (i / FP); pixel = i % FP.
    function [15:0] expected_pix;
        input integer base_frame;
        input integer i;
        integer f;
        begin
            f = base_frame + (i / FP);
            expected_pix = f * 1000 + (i % FP);
        end
    endfunction

    localparam integer WIN_PIX = (PRE+POST)*FP;
    integer i;
    initial begin
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk);

        // Two windows are served (the second was queued during the first readout).
        for (i = 0; i < 200000 && got < 2*WIN_PIX; i = i + 1) @(posedge clk);
        repeat (20) @(posedge clk);

        $display("captured frames=%0d pixels=%0d overrun=%b pending=%b", got/FP, got, overrun, pending_flag);
        if (got != 2*WIN_PIX) begin
            errors = errors + 1;
            $display("FAIL: expected %0d pixels (two windows), got %0d", 2*WIN_PIX, got);
        end
        for (i = 0; i < WIN_PIX; i = i + 1) begin
            if (cap[i] !== expected_pix(EVENT_FRAME-PRE, i)) begin
                errors = errors + 1;
                $display("FAIL: window1 pixel %0d got %0d want %0d", i, cap[i], expected_pix(EVENT_FRAME-PRE, i));
                if (errors > 6) i = WIN_PIX;
            end
        end
        for (i = WIN_PIX; i < 2*WIN_PIX; i = i + 1) begin
            if (cap[i] !== expected_pix(EVENT_FRAME, i-WIN_PIX)) begin
                errors = errors + 1;
                $display("FAIL: window2 pixel %0d got %0d want %0d", i-WIN_PIX, cap[i], expected_pix(EVENT_FRAME, i-WIN_PIX));
                if (errors > 12) i = 2*WIN_PIX;
            end
        end

        if (errors == 0) $display("PASS: ddr_evidence_ring all checks");
        else $display("FAIL: ddr_evidence_ring %0d errors", errors);
        $finish;
    end
endmodule
