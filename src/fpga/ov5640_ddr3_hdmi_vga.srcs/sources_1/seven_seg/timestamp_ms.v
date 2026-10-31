`timescale 1ns/1ps

// Free-running millisecond counter. Used as the FPGA time base so that event
// records, UART packets and the host all share one monotonic clock instead of
// reusing the frame counter.
module timestamp_ms #(
    parameter integer CLK_HZ = 74250000
) (
    input             clk,
    input             rst,
    output reg [31:0] timestamp_ms
);

    localparam integer DIV_CALC = CLK_HZ / 1000;
    localparam integer DIV = (DIV_CALC < 1) ? 1 : DIV_CALC;

    reg [31:0] div_cnt;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            div_cnt      <= 32'd0;
            timestamp_ms <= 32'd0;
        end else if (div_cnt >= DIV - 1) begin
            div_cnt      <= 32'd0;
            timestamp_ms <= timestamp_ms + 32'd1;
        end else begin
            div_cnt <= div_cnt + 32'd1;
        end
    end

endmodule
