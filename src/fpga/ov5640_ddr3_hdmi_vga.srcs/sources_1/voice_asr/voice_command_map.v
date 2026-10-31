`timescale 1ns/1ps

// Maps a recognised WonderEcho word ID to the same operator actions as the
// board keys, so a spoken word and a key press are interchangeable:
//
//   ACK_ID    -> acknowledge alarm / reset workflow (like S1)
//   MUTE_ID   -> toggle the buzzer mute               (like S2)
//   MANUAL_ID -> manual evidence trigger              (like S3)
//
// Any other ID is ignored but still recorded in last_id, and a one-clock pulse
// is produced for the mapped actions.
module voice_command_map #(
    parameter [7:0] ACK_ID    = 8'd1,
    parameter [7:0] MUTE_ID   = 8'd2,
    parameter [7:0] MANUAL_ID = 8'd3
) (
    input         clk,
    input         rst,
    input         word_valid,
    input  [7:0]  word_id,
    output reg    ack_pulse,
    output reg    mute_pulse,
    output reg    manual_pulse,
    output reg [7:0] last_id
);

    always @(posedge clk) begin
        if (rst) begin
            ack_pulse    <= 1'b0;
            mute_pulse   <= 1'b0;
            manual_pulse <= 1'b0;
            last_id      <= 8'd0;
        end else begin
            ack_pulse    <= 1'b0;
            mute_pulse   <= 1'b0;
            manual_pulse <= 1'b0;

            if (word_valid) begin
                last_id <= word_id;
                if (word_id == ACK_ID)
                    ack_pulse <= 1'b1;
                else if (word_id == MUTE_ID)
                    mute_pulse <= 1'b1;
                else if (word_id == MANUAL_ID)
                    manual_pulse <= 1'b1;
            end
        end
    end

endmodule
