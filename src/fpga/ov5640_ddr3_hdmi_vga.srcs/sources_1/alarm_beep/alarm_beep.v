`timescale 1ns/1ps

// Passive-buzzer driver. Alarm is a continuous tone; warning is a short
// periodic tone. The output is low during reset and normal operation.
module alarm_beep #(
    parameter integer CLOCK_HZ       = 50000000,
    parameter integer TONE_HZ        = 2000,
    parameter integer WARNING_ON_MS  = 150,
    parameter integer WARNING_OFF_MS = 850
) (
    input      clk,
    input      rst,
    input      warning_active,
    input      alarm_active,
    input      mute,
    output     beep
);

    reg beep_raw;

    // Operator mute suppresses the output without disturbing the tone
    // generator, so unmuting resumes the correct pattern immediately.
    assign beep = beep_raw & ~mute;

    localparam integer TONE_HALF_CALC = CLOCK_HZ / (TONE_HZ * 2);
    localparam integer TONE_HALF_CYCLES =
        (TONE_HALF_CALC < 1) ? 1 : TONE_HALF_CALC;
    localparam integer WARNING_ON_CYCLES_CALC =
        (CLOCK_HZ / 1000) * WARNING_ON_MS;
    localparam integer WARNING_OFF_CYCLES_CALC =
        (CLOCK_HZ / 1000) * WARNING_OFF_MS;
    localparam integer WARNING_ON_CYCLES =
        (WARNING_ON_CYCLES_CALC < 1) ? 1 : WARNING_ON_CYCLES_CALC;
    localparam integer WARNING_OFF_CYCLES =
        (WARNING_OFF_CYCLES_CALC < 1) ? 1 : WARNING_OFF_CYCLES_CALC;

    localparam [1:0] MODE_OFF     = 2'd0;
    localparam [1:0] MODE_WARNING = 2'd1;
    localparam [1:0] MODE_ALARM   = 2'd2;

    wire [1:0] requested_mode = alarm_active ? MODE_ALARM :
                                 (warning_active ? MODE_WARNING : MODE_OFF);

    reg [1:0]  mode;
    reg [31:0] tone_count;
    reg [31:0] pattern_count;
    reg        pattern_on;

    always @(posedge clk) begin
        if (rst) begin
            mode          <= MODE_OFF;
            tone_count    <= 32'd0;
            pattern_count <= 32'd0;
            pattern_on    <= 1'b0;
            beep_raw      <= 1'b0;
        end else if (requested_mode != mode) begin
            mode          <= requested_mode;
            tone_count    <= 32'd0;
            pattern_count <= 32'd0;
            pattern_on    <= (requested_mode != MODE_OFF);
            beep_raw      <= 1'b0;
        end else begin
            if (mode == MODE_OFF) begin
                tone_count    <= 32'd0;
                pattern_count <= 32'd0;
                pattern_on    <= 1'b0;
                beep_raw      <= 1'b0;
            end else begin
                if (mode == MODE_ALARM) begin
                    pattern_on    <= 1'b1;
                    pattern_count <= 32'd0;
                end else if (pattern_on) begin
                    if (pattern_count >= WARNING_ON_CYCLES - 1) begin
                        pattern_count <= 32'd0;
                        pattern_on    <= 1'b0;
                    end else begin
                        pattern_count <= pattern_count + 32'd1;
                    end
                end else if (pattern_count >= WARNING_OFF_CYCLES - 1) begin
                    pattern_count <= 32'd0;
                    pattern_on    <= 1'b1;
                end else begin
                    pattern_count <= pattern_count + 32'd1;
                end

                if (pattern_on) begin
                    if (tone_count >= TONE_HALF_CYCLES - 1) begin
                        tone_count <= 32'd0;
                        beep_raw   <= ~beep_raw;
                    end else begin
                        tone_count <= tone_count + 32'd1;
                    end
                end else begin
                    tone_count <= 32'd0;
                    beep_raw   <= 1'b0;
                end
            end
        end
    end

endmodule
