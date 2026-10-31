`timescale 1ns/1ps
////////////////////////////////////////////////////////////////////////////////////
// fullscreen_monitor_tb - self-checking test.
//
// Scene: 32x24 frames, SAMPLE_SHIFT=2 -> 8x6 = 48 grid cells.
//   A,B : flat reference frames.
//   C,D : an 8x8 block is changed -> 2x2 = 4 changed cells.
//   E   : same as D -> 0 changed cells.
// Expected active_cells = 4 after D (reports C), then 0 after E (reports D).
////////////////////////////////////////////////////////////////////////////////////
module fullscreen_monitor_tb;

    reg         clk = 1'b0;
    reg         rst = 1'b1;
    reg  [23:0] pixel_in = 24'd0;
    reg  [11:0] x = 12'd0;
    reg  [11:0] y = 12'd0;
    reg         de = 1'b0;
    reg         sof = 1'b0;
    wire [7:0]  activity_global;
    wire [15:0] active_cells;
    wire [7:0]  luma_avg;

    always #5 clk = ~clk;

    fullscreen_monitor #(
        .SAMPLE_SHIFT(2),
        .GRID_WIDTH(8),
        .GRID_HEIGHT(6),
        .SCORE_SHIFT(0),
        .NOISE_FLOOR(8'd0)
    ) dut (
        .clk            (clk),
        .rst            (rst),
        .pixel_in       (pixel_in),
        .x              (x),
        .y              (y),
        .de             (de),
        .sof            (sof),
        .activity_global(activity_global),
        .active_cells   (active_cells),
        .luma_avg       (luma_avg)
    );

    task drive_frame;
        input [7:0] base_gray;
        input       changed_block;
        integer xx;
        integer yy;
        reg [7:0] g;
        begin
            @(negedge clk);
            sof = 1'b1;
            de  = 1'b0;
            x   = 12'd0;
            y   = 12'd0;
            pixel_in = {base_gray, base_gray, base_gray};

            @(negedge clk);
            sof = 1'b0;
            for (yy = 0; yy < 24; yy = yy + 1) begin
                for (xx = 0; xx < 32; xx = xx + 1) begin
                    x = xx;
                    y = yy;
                    de = 1'b1;
                    if (changed_block && xx < 8 && yy < 8)
                        g = 8'hf0;
                    else
                        g = base_gray;
                    pixel_in = {g, g, g};
                    @(negedge clk);
                end
            end
            de = 1'b0;
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst = 1'b0;

        drive_frame(8'd100, 1'b0);   // A: fill
        drive_frame(8'd100, 1'b0);   // B: reference ready
        drive_frame(8'd100, 1'b1);   // C: changed -> 4 cells counted
        drive_frame(8'd100, 1'b1);   // D: reports C
        if (active_cells !== 16'd4) begin
            $display("FAIL: expected active_cells=4 after D, got %0d", active_cells);
            $finish;
        end
        if (activity_global === 8'd0) begin
            $display("FAIL: activity_global did not rise");
            $finish;
        end

        drive_frame(8'd100, 1'b1);   // E: reports D -> no new change
        if (active_cells !== 16'd0) begin
            $display("FAIL: expected active_cells=0 after E, got %0d", active_cells);
            $finish;
        end

        $display("PASS: fullscreen_monitor (global=%0d)", activity_global);
        $finish;
    end

endmodule
