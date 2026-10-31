`timescale 1ns/1ps

// Renders a three-line Chinese status panel on top of the video using the
// generated 16x16 CJK glyph ROM. Pure combinational: it is part of the
// existing pixel pipeline, so it adds no clock domain.
//
// Geometry: 12 cells per line, each cell 16x16 pixels, so the panel is
// 192x48 and cell/row selection is pure bit slicing (no dividers).
//
// ExamGuard panel:
//   状态 候考
//   身份 未核验
//   事件 50 风险3
module text_overlay #(
    parameter [11:0] X0        = 12'd8,
    parameter [11:0] Y0        = 12'd24,
    parameter [11:0] PANEL_W   = 12'd192,
    parameter [11:0] PANEL_H   = 12'd48,
    parameter [23:0] FG_COLOR  = 24'hF8FAFC,
    parameter [23:0] BG_COLOR  = 24'h101820
) (
    input  [11:0] x,
    input  [11:0] y,
    input  [3:0]  stage_id,
    input  [3:0]  risk_level,
    input  [3:0]  zone_id,
    input  [7:0]  event_code,
    input         mute,
    output        text_active,
    output [23:0] text_pixel
);

    // CJK glyph codes. Must match the table order in tools/gen_font_cn.py.
    localparam [7:0] SP       = 8'h20;
    localparam [7:0] C_ZHUANG = 8'h80; // 状
    localparam [7:0] C_TAI    = 8'h81; // 态
    localparam [7:0] C_DAI    = 8'h82; // 待
    localparam [7:0] C_JI     = 8'h83; // 机
    localparam [7:0] C_WAN    = 8'h88; // 完
    localparam [7:0] C_CHENG  = 8'h89; // 成
    localparam [7:0] C_SHI    = 8'h8E; // 事
    localparam [7:0] C_JIAN   = 8'h8F; // 件
    localparam [7:0] C_FENG   = 8'h90; // 风
    localparam [7:0] C_XIAN   = 8'h91; // 险
    localparam [7:0] C_JING   = 8'h92; // 静
    localparam [7:0] C_YIN    = 8'h93; // 音
    localparam [7:0] C_HOU    = 8'h97; // 候
    localparam [7:0] C_KAO    = 8'h98; // 考
    localparam [7:0] C_HE     = 8'h99; // 核
    localparam [7:0] C_YAN    = 8'h9A; // 验
    localparam [7:0] C_SHI2   = 8'h9B; // 试
    localparam [7:0] C_JIAO   = 8'h9C; // 交
    localparam [7:0] C_JUAN   = 8'h9D; // 卷
    localparam [7:0] C_SHEN   = 8'h9E; // 身
    localparam [7:0] C_FEN    = 8'h9F; // 份
    localparam [7:0] C_YI     = 8'hA0; // 已
    localparam [7:0] C_WEI    = 8'hA1; // 未

    reg [95:0] line0_text;
    reg [95:0] line1_text;
    reg [95:0] line2_text;

    function [7:0] hex_code;
        input [3:0] v;
        begin
            if (v < 4'd10)
                hex_code = 8'h30 + {4'd0, v};
            else
                hex_code = 8'h41 + {4'd0, v} - 8'd10;
        end
    endfunction

    function [7:0] dec_code;
        input [3:0] v;
        begin
            dec_code = 8'h30 + {4'd0, v};
        end
    endfunction

    // Stage line: 状态 待机/候考/核验/考试/交卷/完成
    always @* begin
        case (stage_id)
            4'd0: line0_text = {C_ZHUANG, C_TAI, SP, C_DAI,  C_JI,
                                SP, SP, SP, SP, SP, SP, SP};
            4'd1: line0_text = {C_ZHUANG, C_TAI, SP, C_HOU,  C_KAO,
                                SP, SP, SP, SP, SP, SP, SP};
            4'd2: line0_text = {C_ZHUANG, C_TAI, SP, C_HE,   C_YAN,
                                SP, SP, SP, SP, SP, SP, SP};
            4'd3: line0_text = {C_ZHUANG, C_TAI, SP, C_KAO,  C_SHI2,
                                SP, SP, SP, SP, SP, SP, SP};
            4'd4: line0_text = {C_ZHUANG, C_TAI, SP, C_JIAO, C_JUAN,
                                SP, SP, SP, SP, SP, SP, SP};
            4'd5: line0_text = {C_ZHUANG, C_TAI, SP, C_WAN,  C_CHENG,
                                SP, SP, SP, SP, SP, SP, SP};
            default: line0_text = {C_ZHUANG, C_TAI, SP, SP, SP,
                                   SP, SP, SP, SP, SP, SP, SP};
        endcase
    end

    // Identity line: 身份 已核验 / 未核验 (verified once the exam is running).
    always @* begin
        if (stage_id >= 4'd3)
            line1_text = {C_SHEN, C_FEN, SP, C_YI, C_HE, C_YAN,
                          SP, SP, SP, SP, SP, SP};
        else
            line1_text = {C_SHEN, C_FEN, SP, C_WEI, C_HE, C_YAN,
                          SP, SP, SP, SP, SP, SP};
    end

    // Event line: 事件 EE 风险R [静音]
    always @* begin
        line2_text = {
            C_SHI,
            C_JIAN,
            SP,
            hex_code(event_code[7:4]),
            hex_code(event_code[3:0]),
            SP,
            C_FENG,
            C_XIAN,
            dec_code(risk_level[3:0]),
            SP,
            mute ? C_JING : SP,
            mute ? C_YIN  : SP
        };
    end

    wire [11:0] dx = x - X0;
    wire [11:0] dy = y - Y0;

    // 12 cells of 16 px and 3 lines of 16 px, so everything is bit slicing.
    wire [1:0]  line   = dy[5:4];
    wire [3:0]  row    = dy[3:0];
    wire [3:0]  col    = dx[7:4];
    wire [3:0]  cell_x = dx[3:0];

    wire within_panel = (x >= X0) && (x < X0 + PANEL_W) &&
                  (y >= Y0) && (y < Y0 + PANEL_H);

    wire [95:0] line_sel = (line == 2'd0) ? line0_text :
                           (line == 2'd1) ? line1_text : line2_text;

    wire [7:0] code = line_sel >> (8 * (4'd11 - col));

    wire [15:0] glyph_bits;
    char_rom_cn char_rom_cn_inst (
        .code (code),
        .row  (row),
        .bits (glyph_bits)
    );

    wire glyph_on = glyph_bits[15 - cell_x];

    // Background follows each text line instead of covering 12 cells always.
    wire [11:0] line_width = line==0 ? 12'd80 : line==1 ? 12'd96 :
                            mute ? 12'd192 : 12'd144;
    assign text_active = within_panel && dx < line_width;
    assign text_pixel  = (within_panel && glyph_on) ? FG_COLOR : BG_COLOR;

endmodule
