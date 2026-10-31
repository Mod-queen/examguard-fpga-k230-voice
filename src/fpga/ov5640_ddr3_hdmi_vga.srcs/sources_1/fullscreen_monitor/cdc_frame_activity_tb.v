`timescale 1ns/1ps
module cdc_frame_activity_tb;

    reg         src_clk = 1'b0;
    reg         src_rst = 1'b1;
    reg         src_frame = 1'b0;
    reg  [7:0]  src_activity = 8'd0;
    reg  [15:0] src_cells = 16'd0;

    reg         dst_clk = 1'b0;
    reg         dst_rst = 1'b1;
    wire        dst_pulse;
    wire [7:0]  dst_activity;
    wire [15:0] dst_cells;

    always #5  src_clk = ~src_clk;   // ~100 MHz
    always #10 dst_clk = ~dst_clk;   // 50 MHz

    cdc_frame_activity dut (
        .src_clk(src_clk), .src_rst(src_rst),
        .src_frame(src_frame), .src_activity(src_activity), .src_cells(src_cells),
        .dst_clk(dst_clk), .dst_rst(dst_rst),
        .dst_pulse(dst_pulse), .dst_activity(dst_activity), .dst_cells(dst_cells)
    );

    initial begin
        repeat (3) @(negedge src_clk);
        src_rst = 1'b0;
        repeat (3) @(negedge dst_clk);
        dst_rst = 1'b0;

        // Frame 1.
        @(negedge src_clk);
        src_activity = 8'd100; src_cells = 16'd42; src_frame = 1'b1;
        @(negedge src_clk); src_frame = 1'b0;

        repeat (10) @(negedge dst_clk);
        if (dst_activity !== 8'd100 || dst_cells !== 16'd42) begin
            $display("FAIL: frame1 dst_activity=%0d dst_cells=%0d", dst_activity, dst_cells);
            $finish;
        end

        // Frame 2.
        @(negedge src_clk);
        src_activity = 8'd200; src_cells = 16'd7; src_frame = 1'b1;
        @(negedge src_clk); src_frame = 1'b0;

        repeat (10) @(negedge dst_clk);
        if (dst_activity !== 8'd200 || dst_cells !== 16'd7) begin
            $display("FAIL: frame2 dst_activity=%0d dst_cells=%0d", dst_activity, dst_cells);
            $finish;
        end

        $display("PASS: cdc_frame_activity");
        $finish;
    end

endmodule
