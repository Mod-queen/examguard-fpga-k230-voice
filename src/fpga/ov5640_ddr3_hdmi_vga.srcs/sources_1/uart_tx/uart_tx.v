`timescale 1ns/1ps

// 8-N-1 UART transmitter. tx_start is sampled only while busy is low.
module uart_tx #(
    parameter integer CLK_FREQ_HZ = 50000000,
    parameter integer BAUD_RATE   = 115200
) (
    input        clk,
    input        rst,
    input        tx_start,
    input  [7:0] tx_data,
    output reg   tx,
    output reg   busy
);

    localparam integer CLKS_PER_BIT_CALC = CLK_FREQ_HZ / BAUD_RATE;
    localparam integer CLKS_PER_BIT =
        (CLKS_PER_BIT_CALC < 1) ? 1 : CLKS_PER_BIT_CALC;

    reg [31:0] clock_count;
    reg [3:0]  bit_index;
    reg [7:0]  data_reg;

    always @(posedge clk) begin
        if (rst) begin
            clock_count <= 32'd0;
            bit_index   <= 4'd0;
            data_reg    <= 8'd0;
            tx          <= 1'b1;
            busy        <= 1'b0;
        end else if (!busy) begin
            tx <= 1'b1;
            if (tx_start) begin
                data_reg    <= tx_data;
                clock_count <= 32'd0;
                bit_index   <= 4'd0;
                tx          <= 1'b0;
                busy        <= 1'b1;
            end
        end else if (clock_count >= CLKS_PER_BIT - 1) begin
            clock_count <= 32'd0;

            if (bit_index < 4'd8) begin
                tx        <= data_reg[bit_index];
                bit_index <= bit_index + 4'd1;
            end else if (bit_index == 4'd8) begin
                tx        <= 1'b1;
                bit_index <= 4'd9;
            end else begin
                tx        <= 1'b1;
                bit_index <= 4'd0;
                busy      <= 1'b0;
            end
        end else begin
            clock_count <= clock_count + 32'd1;
        end
    end

endmodule
