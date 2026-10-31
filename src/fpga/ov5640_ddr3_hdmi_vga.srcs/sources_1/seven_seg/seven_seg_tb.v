`timescale 1ns/1ps

module seven_seg_tb;

    reg clk;
    reg rst;
    reg [31:0] disp_data;
    wire [7:0] sel;
    wire [6:0] seg;
    wire dio;
    wire rclk;
    wire sclk;

    reg [15:0] cap;
    reg [15:0] latch_value;
    integer    sclk_edges;
    integer    sclk_edges_at_latch;

    // A very slow scan keeps the digit selection stable while the shift
    // register is loaded, so the captured value is deterministic.
    hex8 #(
        .CLK_HZ  (1000),
        .SCAN_HZ (1)
    ) hex8_inst (
        .clk       (clk),
        .rst       (rst),
        .en        (1'b1),
        .disp_data (disp_data),
        .sel       (sel),
        .seg       (seg)
    );

    hc595_driver #(
        .CLK_HZ  (1000),
        .CNT_MAX (1)
    ) hc595_driver_inst (
        .clk   (clk),
        .rst   (rst),
        .data  ({1'b0, seg, sel}),
        .s_en  (1'b1),
        .sh_cp (sclk),
        .st_cp (rclk),
        .ds    (dio)
    );

    always #5 clk = ~clk;

    // The 595 samples the data line on the rising edge of the shift clock.
    always @(posedge sclk) begin
        if (!rst) begin
            cap <= {cap[14:0], dio};
            sclk_edges <= sclk_edges + 1;
        end
    end

    always @(posedge rclk) begin
        if (!rst) begin
            latch_value <= cap;
            sclk_edges_at_latch <= sclk_edges;
        end
    end

    integer wait_count;

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        disp_data = 32'h0000_0005;
        cap = 16'd0;
        latch_value = 16'd0;
        sclk_edges = 0;
        sclk_edges_at_latch = 0;

        repeat (4) @(negedge clk);
        rst = 1'b0;

        // Wait for the first complete shift frame to be latched.
        wait_count = 0;
        while ((latch_value === 16'd0) && (wait_count < 20000)) begin
            @(negedge clk);
            wait_count = wait_count + 1;
        end

        if (latch_value !== 16'h1201) begin
            $display("FAIL: latched value %04h, expected 1201", latch_value);
            $finish;
        end

        if (sclk_edges_at_latch !== 16) begin
            $display("FAIL: %0d shift edges before latch, expected 16",
                     sclk_edges_at_latch);
            $finish;
        end

        $display("PASS: seven-segment shift chain");
        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL: seven-segment timeout");
        $finish;
    end

endmodule
