`timescale 1ns/1ps

// Scans an 8-digit multiplexed display. One digit is selected at a time and its
// 7-segment pattern is presented; the 74HC595 chain holds that pattern while the
// next digit is prepared, so persistence of vision shows all eight digits.
//
// Adapted from the ACX750 example set (ch12 hex8). The divided-clock scan was
// replaced with a clock enable so the module adds no extra clock domain.
module hex8 #(
    parameter integer CLK_HZ  = 50000000,
    parameter integer SCAN_HZ = 1000
) (
    input             clk,
    input             rst,
    input             en,
    input      [31:0] disp_data,
    output     [7:0]  sel,
    output reg [6:0]  seg
);

    localparam integer DIV_CALC = CLK_HZ / SCAN_HZ;
    localparam integer DIV = (DIV_CALC < 1) ? 1 : DIV_CALC;

    reg [31:0] div_cnt;
    reg [7:0]  sel_r;
    reg [3:0]  data_tmp;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            div_cnt <= 32'd0;
            sel_r   <= 8'b0000_0001;
        end else if (!en) begin
            div_cnt <= 32'd0;
            sel_r   <= 8'b0000_0001;
        end else if (div_cnt >= DIV - 1) begin
            div_cnt <= 32'd0;
            if (sel_r == 8'b1000_0000)
                sel_r <= 8'b0000_0001;
            else
                sel_r <= sel_r << 1;
        end else begin
            div_cnt <= div_cnt + 32'd1;
        end
    end

    always @* begin
        case (sel_r)
            8'b0000_0001: data_tmp = disp_data[3:0];
            8'b0000_0010: data_tmp = disp_data[7:4];
            8'b0000_0100: data_tmp = disp_data[11:8];
            8'b0000_1000: data_tmp = disp_data[15:12];
            8'b0001_0000: data_tmp = disp_data[19:16];
            8'b0010_0000: data_tmp = disp_data[23:20];
            8'b0100_0000: data_tmp = disp_data[27:24];
            8'b1000_0000: data_tmp = disp_data[31:28];
            default:      data_tmp = 4'b0000;
        endcase
    end

    // Common-anode segments, active low, matching the board display.
    always @* begin
        case (data_tmp)
            4'h0: seg = 7'b1000000;
            4'h1: seg = 7'b1111001;
            4'h2: seg = 7'b0100100;
            4'h3: seg = 7'b0110000;
            4'h4: seg = 7'b0011001;
            4'h5: seg = 7'b0010010;
            4'h6: seg = 7'b0000010;
            4'h7: seg = 7'b1111000;
            4'h8: seg = 7'b0000000;
            4'h9: seg = 7'b0010000;
            4'ha: seg = 7'b0001000;
            4'hb: seg = 7'b0000011;
            4'hc: seg = 7'b1000110;
            4'hd: seg = 7'b0100001;
            4'he: seg = 7'b0000110;
            default: seg = 7'b0001110;
        endcase
    end

    assign sel = en ? sel_r : 8'b0000_0000;

endmodule
