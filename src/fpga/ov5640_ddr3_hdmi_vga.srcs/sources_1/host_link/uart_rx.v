`timescale 1ns/1ps

// 8-N-1 UART receiver. The input is synchronized before any decision, the
// start bit is validated at its midpoint, and each data bit is sampled at its
// centre so small baud mismatches are tolerated.
module uart_rx #(
    parameter integer CLK_FREQ_HZ = 50000000,
    parameter integer BAUD_RATE   = 115200
) (
    input             clk,
    input             rst,
    input             rx,
    output reg [7:0]  data,
    output reg        valid
);

    localparam integer CLKS_CALC = CLK_FREQ_HZ / BAUD_RATE;
    localparam integer CLKS_PER_BIT = (CLKS_CALC < 4) ? 4 : CLKS_CALC;
    localparam integer HALF_BIT = CLKS_PER_BIT / 2;

    (* ASYNC_REG = "TRUE" *) reg rx_meta;
    (* ASYNC_REG = "TRUE" *) reg rx_sync;
    reg rx_prev;
    wire rx_fall = rx_prev & ~rx_sync;

    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_START = 2'd1;
    localparam [1:0] S_DATA  = 2'd2;
    localparam [1:0] S_STOP  = 2'd3;

    reg [1:0]  state;
    reg [15:0] cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  shift;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rx_meta  <= 1'b1;
            rx_sync  <= 1'b1;
            rx_prev  <= 1'b1;
            state    <= S_IDLE;
            cnt      <= 16'd0;
            bit_idx  <= 3'd0;
            shift    <= 8'd0;
            data     <= 8'd0;
            valid    <= 1'b0;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
            rx_prev <= rx_sync;
            valid   <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (rx_fall) begin
                        cnt   <= 16'd0;
                        state <= S_START;
                    end
                end

                S_START: begin
                    // Confirm the start bit is still low at its centre.
                    if (cnt == HALF_BIT - 1) begin
                        cnt <= 16'd0;
                        if (rx_sync == 1'b0) begin
                            bit_idx <= 3'd0;
                            state   <= S_DATA;
                        end else begin
                            state <= S_IDLE;
                        end
                    end else begin
                        cnt <= cnt + 16'd1;
                    end
                end

                S_DATA: begin
                    // First sample lands at 1.5 bit times, the centre of bit 0.
                    if (cnt == CLKS_PER_BIT - 1) begin
                        cnt   <= 16'd0;
                        shift <= {rx_sync, shift[7:1]};
                        if (bit_idx == 3'd7)
                            state <= S_STOP;
                        else
                            bit_idx <= bit_idx + 3'd1;
                    end else begin
                        cnt <= cnt + 16'd1;
                    end
                end

                S_STOP: begin
                    if (cnt == CLKS_PER_BIT - 1) begin
                        cnt   <= 16'd0;
                        state <= S_IDLE;
                        // A low stop bit is a framing error: drop the byte.
                        if (rx_sync == 1'b1) begin
                            data  <= shift;
                            valid <= 1'b1;
                        end
                    end else begin
                        cnt <= cnt + 16'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
