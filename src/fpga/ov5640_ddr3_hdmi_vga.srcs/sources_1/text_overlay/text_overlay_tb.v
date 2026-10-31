`timescale 1ns/1ps

module text_overlay_tb;

    localparam [23:0] FG = 24'hF8FAFC;

    localparam [11:0] X0 = 12'd8;
    localparam [11:0] Y0 = 12'd24;
    localparam integer CELL = 16;
    localparam integer COLS = 12;

    reg  [11:0] x;
    reg  [11:0] y;
    reg  [3:0]  stage_id;
    reg  [3:0]  risk_level;
    reg  [3:0]  zone_id;
    reg  [7:0]  event_code;
    reg         mute;
    wire        text_active;
    wire [23:0] text_pixel;

    text_overlay dut (
        .x          (x),
        .y          (y),
        .stage_id   (stage_id),
        .risk_level (risk_level),
        .zone_id    (zone_id),
        .event_code (event_code),
        .mute       (mute),
        .text_active(text_active),
        .text_pixel (text_pixel)
    );

    // Reference font for pixel-exact comparison.
    reg  [7:0]  ref_code;
    reg  [3:0]  ref_row;
    wire [15:0] ref_bits;
    char_rom_cn ref_rom (
        .code (ref_code),
        .row  (ref_row),
        .bits (ref_bits)
    );

    integer lx;
    integer ly;
    integer r;
    integer cx;
    integer checked;
    reg     expected;

    task check_code_at;
        input integer line_index;
        input integer col_index;
        input [7:0]   expected_code;
        begin
            ref_code = expected_code;
            for (r = 0; r < CELL; r = r + 1) begin
                ref_row = r[3:0];
                #1;
                for (cx = 0; cx < CELL; cx = cx + 1) begin
                    x = X0 + col_index * CELL + cx;
                    y = Y0 + line_index * CELL + r;
                    #1;
                    expected = ref_bits[15 - cx];
                    if ((text_pixel == FG) !== expected) begin
                        $display("FAIL: line %0d col %0d row %0d x %0d code %02x expected %b",
                                 line_index, col_index, r, cx, expected_code, expected);
                        $finish;
                    end
                    checked = checked + 1;
                end
            end
        end
    endtask

    initial begin
        x = 12'd0;
        y = 12'd0;
        stage_id = 4'd2;      // 操作
        risk_level = 4'd2;    // 风险2
        zone_id = 4'd3;       // 禁区
        event_code = 8'h40;
        mute = 1'b0;
        checked = 0;

        // 状态 操作
        check_code_at(0, 0, 8'h80); // 状
        check_code_at(0, 1, 8'h81); // 态
        check_code_at(0, 2, 8'h20); // space
        check_code_at(0, 3, 8'h86); // 操
        check_code_at(0, 4, 8'h87); // 作
        // 区域 禁区
        check_code_at(1, 0, 8'h8A); // 区
        check_code_at(1, 1, 8'h8B); // 域
        check_code_at(1, 3, 8'h8D); // 禁
        check_code_at(1, 4, 8'h8A); // 区
        // 事件 40 风险2
        check_code_at(2, 0, 8'h8E); // 事
        check_code_at(2, 1, 8'h8F); // 件
        check_code_at(2, 3, 8'h34); // '4'
        check_code_at(2, 4, 8'h30); // '0'
        check_code_at(2, 6, 8'h90); // 风
        check_code_at(2, 7, 8'h91); // 险
        check_code_at(2, 8, 8'h32); // '2'

        // 静音 appears only when muted.
        mute = 1'b1;
        check_code_at(2, 10, 8'h92); // 静
        check_code_at(2, 11, 8'h93); // 音
        mute = 1'b0;

        // Render the whole panel so the result can be eyeballed.
        $display("---- panel: stage=operation zone=forbidden code=40 risk=2 ----");
        for (ly = 0; ly < 48; ly = ly + 1) begin
            for (lx = 0; lx < 192; lx = lx + 1) begin
                x = X0 + lx;
                y = Y0 + ly;
                #1;
                if (text_active && (text_pixel == FG))
                    $write("#");
                else if (text_active)
                    $write(".");
                else
                    $write(" ");
            end
            $write("\n");
        end

        // Outside the panel nothing is drawn.
        x = 12'd200;
        y = 12'd100;
        #1;
        if (text_active) begin
            $display("FAIL: panel active outside its area");
            $finish;
        end
        x = 12'd8;
        y = 12'd23;
        #1;
        if (text_active) begin
            $display("FAIL: panel active above its area");
            $finish;
        end
        x = 12'd8;
        y = 12'd72;
        #1;
        if (text_active) begin
            $display("FAIL: panel active below its area");
            $finish;
        end

        $display("PASS: text overlay (%0d pixels checked)", checked);
        $finish;
    end

endmodule
