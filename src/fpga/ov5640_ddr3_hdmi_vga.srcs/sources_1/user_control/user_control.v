`timescale 1ns/1ps

// Map the four spare board keys to operator functions. Keys are active low.
//
//   KEY[0] : acknowledge alarm, resets the workflow to IDLE
//   KEY[1] : toggle buzzer mute (latch, shown on the display status bar)
//   KEY[2] : manual evidence trigger, for demonstrating the event ring
//   KEY[3] : reserved
module user_control #(
    parameter integer CLK_FREQ_HZ = 50000000,
    parameter integer DEBOUNCE_MS = 10
) (
    input         clk,
    input         rst,
    input  [3:0]  key,
    // A one-clock pulse from the voice assistant to toggle the mute, so a
    // spoken command and S2 are interchangeable.
    input         mute_toggle_pulse,
    output        alarm_ack_pulse,
    output reg    buzzer_mute,
    output        manual_event_pulse,
    output [3:0]  key_pressed,
    output [3:0]  key_press_pulse
);

    wire [3:0] pressed;
    wire [3:0] press_pulse;

    genvar index;
    generate
        for (index = 0; index < 4; index = index + 1) begin : g_key
            key_debounce #(
                .CLK_FREQ_HZ (CLK_FREQ_HZ),
                .DEBOUNCE_MS (DEBOUNCE_MS)
            ) key_debounce_inst (
                .clk         (clk),
                .rst         (rst),
                .key_n       (key[index]),
                .pressed     (pressed[index]),
                .press_pulse (press_pulse[index])
            );
        end
    endgenerate

    assign key_pressed     = pressed;
    assign key_press_pulse = press_pulse;

    assign alarm_ack_pulse    = press_pulse[0];
    assign manual_event_pulse = press_pulse[2];

    always @(posedge clk) begin
        if (rst)
            buzzer_mute <= 1'b0;
        else if (press_pulse[1] | mute_toggle_pulse)
            buzzer_mute <= ~buzzer_mute;
    end

endmodule
