`timescale 1ns/1ps
// Coherent HDMI snapshot is applied only at a frame boundary; ack returns to
// the caller through a holding CDC. Text upload is not itself presentation.
module candidate_overlay(
    input wire clk,rst,sof,snapshot_valid,
    input wire [127:0] text_codes,
    input wire [31:0] text_token,seat,
    input wire candidate_valid,
    input wire [2:0] stage,
    input wire [11:0] x,y,
    input wire de,
    input wire [23:0] pixel_in,
    output wire [23:0] pixel_out,
    output reg [31:0] displayed_token
);
    reg [127:0] held_text;
    reg [31:0] held_seat;
    reg visible;
    reg [7:0] code;
    wire active=visible && de && x>=16 && x<368 && y>=88 && y<152;
    wire [11:0] local_x=x-16,local_y=y-88;
    wire [4:0] column=local_x[8:4];
    wire [1:0] line=local_y[5:4];
    // Digits use a 10-pixel advance instead of a full 16-pixel Chinese
    // character cell. Keep the original glyph's central 10 columns (3..12).
    wire number_pixel=line==1 && local_x>=48 && local_x<148;
    wire [9:0] number_ink;
    // Decode ten held characters in parallel. The pixel's x coordinate only
    // selects a glyph BIT; it never traverses divide/modulo -> text mux ->
    // general Chinese font ROM -> glyph-bit mux in one HDMI clock.
    genvar digit;
    generate for(digit=0;digit<10;digit=digit+1) begin : compact_digits
        wire [15:0] row_bits;
        wire [3:0] digit_code=held_text[75-digit*8 -:4];
        wire [3:0] bit_index=4'd12-(x-(64+digit*10));
        candidate_glyph digit_font(.code({4'h3,digit_code}),.row(local_y[3:0]),.bits(row_bits));
        assign number_ink[digit]=x>=64+digit*10 && x<74+digit*10 && row_bits[bit_index];
    end endgenerate
    wire [15:0] bits;
    candidate_glyph rom(.code(code),.row(local_y[3:0]),.bits(bits));
    // Palette positions are explicit and mirrored by Python's encoder.
    always @* begin
        code=8'h20;
        case(line)
            0:case(column)
                0:code=8'h80;1:code=8'h81;
                default:if(column>=3 && column<9) code=held_text[127-(column-3)*8 -:8];
            endcase
            1:case(column)
                0:code=8'h82;1:code=8'h83;
                 default:code=8'h20;
            endcase
            2:case(column)
                0:code=8'h82;1:code=8'h84;
                3:code=8'h30+(held_seat[7:0]/100)%10;
                4:code=8'h30+(held_seat[7:0]/10)%10;
                5:code=8'h30+held_seat[7:0]%10;
            endcase
            3:if(stage==2) case(column)
                0:code=8'h8b; // 请
                1:code=8'h8c; // 核
                2:code=8'h8d; // 对
                3:code=8'h8e; // 信
                4:code=8'h8f; // 息
            endcase
            else if(stage==3) case(column)
                0:code=8'h82; // 考
                1:code=8'h9a; // 试
                2:code=8'h9b; // 中
            endcase
        endcase
    end
    wire ink=number_pixel ? |number_ink : bits[15-local_x[3:0]];
    assign pixel_out=active ? (ink ? 24'hf8fafc : 24'h101820) : pixel_in;
    always @(posedge clk) begin
        if(rst) begin visible<=0;held_text<=0;held_seat<=0;displayed_token<=0;end
        else begin
            if(!snapshot_valid || !candidate_valid || stage<2) begin visible<=0;displayed_token<=0;end
            else if(sof) begin
                held_text<=text_codes;held_seat<=seat;visible<=1;displayed_token<=text_token;
            end
        end
    end
endmodule
