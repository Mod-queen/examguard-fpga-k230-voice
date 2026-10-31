`timescale 1ns/1ps

// Synchronize and debounce one active-low mechanical key. The raw input is
// registered twice before any decision so metastability cannot reach the
// debounce counter, and a clean one-clock press pulse is produced.
module key_debounce #(
    parameter integer CLK_FREQ_HZ = 50000000,
    parameter integer DEBOUNCE_MS = 10
) (
    input      clk,
    input      rst,
    input      key_n,
    output reg pressed,
    output reg press_pulse
);

    localparam integer CNT_MAX_CALC = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;
    localparam integer CNT_MAX = (CNT_MAX_CALC < 2) ? 2 : CNT_MAX_CALC;

    (* ASYNC_REG = "TRUE" *) reg key_meta;
    (* ASYNC_REG = "TRUE" *) reg key_sync;
    reg key_stable;
    reg [31:0] cnt;
    reg pressed_d;

    always @(posedge clk) begin
        if (rst) begin
            key_meta    <= 1'b1;
            key_sync    <= 1'b1;
            key_stable  <= 1'b1;
            cnt         <= 32'd0;
            pressed     <= 1'b0;
            pressed_d   <= 1'b0;
            press_pulse <= 1'b0;
        end else begin
            key_meta <= key_n;
            key_sync <= key_meta;

            if (key_sync != key_stable) begin
                if (cnt >= CNT_MAX - 1) begin
                    key_stable <= key_sync;
                    cnt        <= 32'd0;
                end else begin
                    cnt <= cnt + 32'd1;
                end
            end else begin
                cnt <= 32'd0;
            end

            pressed     <= ~key_stable;
            pressed_d   <= pressed;
            press_pulse <= pressed & ~pressed_d;
        end
    end

endmodule
