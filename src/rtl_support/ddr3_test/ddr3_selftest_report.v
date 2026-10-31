`timescale 1ns/1ps

// ASCII report sender for the DDR self-test + DMA results (hex, no division):
//   DDR3 SELFTEST\n
//   B=xxxxxxxx E=xxxxxxxx W=xxxxxxxx R=xxxxxxxx\n   (x4, one per base)
//   DMA R=xxxxxxxx\n                                 (multi-outstanding read cycles)
//   END\n
module ddr3_selftest_report #(
    parameter integer CLK_FREQ_HZ = 100000000,
    parameter integer BAUD_RATE   = 115200
)(
    input               clk,
    input               rst,
    input               start,          // one-cycle pulse to begin
    input  [127:0]      bases,          // 4 x 32-bit
    input  [127:0]      errs,
    input  [127:0]      wcycles,
    input  [127:0]      rcycles,
    input  [31:0]       dma_rcycles,
    output reg          busy,
    output reg          done,
    output              uart_txd
);
    reg [2:0]  line;    // 0 header, 1..4 results, 5 dma, 6 end
    reg [7:0]  col;
    reg        issue;
    wire       tx_busy;
    wire [7:0] tx_data = line_char(line, col);

    uart_tx #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD_RATE(BAUD_RATE)) u_tx (
        .clk(clk), .rst(rst), .tx_start(issue && !tx_busy), .tx_data(tx_data),
        .tx(uart_txd), .busy(tx_busy));

    function [7:0] hexd;
        input [3:0] v;
        begin hexd = (v < 4'd10) ? (8'h30 + {4'b0, v}) : (8'h41 + {4'b0, v} - 8'd10); end
    endfunction

    function [7:0] hex_of;
        input [31:0] word;
        input [2:0]  idx;      // 0 = most significant nibble
        reg [31:0] shifted;
        begin
            shifted = word >> ((7 - idx) * 4);
            hex_of = hexd(shifted[3:0]);
        end
    endfunction

    function [7:0] dma_hex;
        input [2:0] idx;
        begin dma_hex = hex_of(dma_rcycles, idx); end
    endfunction

    function [7:0] line_char;
        input [2:0] ln;
        input [7:0] cx;
        reg [127:0] b, e, w, r;
        begin
            b = bases; e = errs; w = wcycles; r = rcycles;
            if (ln == 3'd0) begin
                case (cx)
                    8'd0: line_char = "D"; 8'd1: line_char = "D"; 8'd2: line_char = "R";
                    8'd3: line_char = "3"; 8'd4: line_char = " "; 8'd5: line_char = "S";
                    8'd6: line_char = "E"; 8'd7: line_char = "L"; 8'd8: line_char = "F";
                    8'd9: line_char = "T"; 8'd10: line_char = "E"; 8'd11: line_char = "S";
                    8'd12: line_char = "T"; 8'd13: line_char = 8'h0d; default: line_char = 8'h0a;
                endcase
            end else if (ln <= 3'd4) begin
                case (cx)
                    8'd0:  line_char = "B";
                    8'd1:  line_char = "=";
                    8'd2:  line_char = hex_of(b[((ln-1)*32) +: 32], 3'd0);
                    8'd3:  line_char = hex_of(b[((ln-1)*32) +: 32], 3'd1);
                    8'd4:  line_char = hex_of(b[((ln-1)*32) +: 32], 3'd2);
                    8'd5:  line_char = hex_of(b[((ln-1)*32) +: 32], 3'd3);
                    8'd6:  line_char = hex_of(b[((ln-1)*32) +: 32], 3'd4);
                    8'd7:  line_char = hex_of(b[((ln-1)*32) +: 32], 3'd5);
                    8'd8:  line_char = hex_of(b[((ln-1)*32) +: 32], 3'd6);
                    8'd9:  line_char = hex_of(b[((ln-1)*32) +: 32], 3'd7);
                    8'd10: line_char = " ";
                    8'd11: line_char = "E";
                    8'd12: line_char = "=";
                    8'd13: line_char = hex_of(e[((ln-1)*32) +: 32], 3'd0);
                    8'd14: line_char = hex_of(e[((ln-1)*32) +: 32], 3'd1);
                    8'd15: line_char = hex_of(e[((ln-1)*32) +: 32], 3'd2);
                    8'd16: line_char = hex_of(e[((ln-1)*32) +: 32], 3'd3);
                    8'd17: line_char = hex_of(e[((ln-1)*32) +: 32], 3'd4);
                    8'd18: line_char = hex_of(e[((ln-1)*32) +: 32], 3'd5);
                    8'd19: line_char = hex_of(e[((ln-1)*32) +: 32], 3'd6);
                    8'd20: line_char = hex_of(e[((ln-1)*32) +: 32], 3'd7);
                    8'd21: line_char = " ";
                    8'd22: line_char = "W";
                    8'd23: line_char = "=";
                    8'd24: line_char = hex_of(w[((ln-1)*32) +: 32], 3'd0);
                    8'd25: line_char = hex_of(w[((ln-1)*32) +: 32], 3'd1);
                    8'd26: line_char = hex_of(w[((ln-1)*32) +: 32], 3'd2);
                    8'd27: line_char = hex_of(w[((ln-1)*32) +: 32], 3'd3);
                    8'd28: line_char = hex_of(w[((ln-1)*32) +: 32], 3'd4);
                    8'd29: line_char = hex_of(w[((ln-1)*32) +: 32], 3'd5);
                    8'd30: line_char = hex_of(w[((ln-1)*32) +: 32], 3'd6);
                    8'd31: line_char = hex_of(w[((ln-1)*32) +: 32], 3'd7);
                    8'd32: line_char = " ";
                    8'd33: line_char = "R";
                    8'd34: line_char = "=";
                    8'd35: line_char = hex_of(r[((ln-1)*32) +: 32], 3'd0);
                    8'd36: line_char = hex_of(r[((ln-1)*32) +: 32], 3'd1);
                    8'd37: line_char = hex_of(r[((ln-1)*32) +: 32], 3'd2);
                    8'd38: line_char = hex_of(r[((ln-1)*32) +: 32], 3'd3);
                    8'd39: line_char = hex_of(r[((ln-1)*32) +: 32], 3'd4);
                    8'd40: line_char = hex_of(r[((ln-1)*32) +: 32], 3'd5);
                    8'd41: line_char = hex_of(r[((ln-1)*32) +: 32], 3'd6);
                    8'd42: line_char = hex_of(r[((ln-1)*32) +: 32], 3'd7);
                    8'd43: line_char = 8'h0d;
                    default: line_char = 8'h0a;   // cx == 44
                endcase
            end else if (ln == 3'd5) begin
                case (cx)
                    8'd0: line_char = "D"; 8'd1: line_char = "M"; 8'd2: line_char = "A";
                    8'd3: line_char = " "; 8'd4: line_char = "R"; 8'd5: line_char = "=";
                    8'd6:  line_char = dma_hex(3'd0);
                    8'd7:  line_char = dma_hex(3'd1);
                    8'd8:  line_char = dma_hex(3'd2);
                    8'd9:  line_char = dma_hex(3'd3);
                    8'd10: line_char = dma_hex(3'd4);
                    8'd11: line_char = dma_hex(3'd5);
                    8'd12: line_char = dma_hex(3'd6);
                    8'd13: line_char = dma_hex(3'd7);
                    8'd14: line_char = 8'h0d; default: line_char = 8'h0a;
                endcase
            end else begin
                case (cx)
                    8'd0: line_char = "E"; 8'd1: line_char = "N"; 8'd2: line_char = "D";
                    8'd3: line_char = 8'h0d; default: line_char = 8'h0a;
                endcase
            end
        end
    endfunction

    wire cur_last = (line == 3'd0) ? (col == 8'd14) :
                    (line <= 3'd4) ? (col == 8'd44) :
                    (line == 3'd5) ? (col == 8'd15) : (col == 8'd4);

    always @(posedge clk) begin
        if (rst) begin
            line <= 3'd0; col <= 8'd0; issue <= 1'b0; busy <= 1'b0; done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (!busy) begin
                if (start) begin
                    busy <= 1'b1; line <= 3'd0; col <= 8'd0; issue <= 1'b1;
                end
            end else begin
                if (issue && !tx_busy) begin
                    issue <= 1'b0;
                    if (cur_last) begin
                        if (line == 3'd6) begin busy <= 1'b0; done <= 1'b1; end
                        else begin line <= line + 3'd1; col <= 8'd0; end
                    end else begin
                        col <= col + 8'd1;
                    end
                end else if (!issue && !tx_busy) begin
                    issue <= 1'b1;
                end
            end
        end
    end
endmodule
