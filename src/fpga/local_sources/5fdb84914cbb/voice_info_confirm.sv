`timescale 1ns/1ps

// Independent 50 MHz candidate. No direct key, UART, I2C or exam-FSM ownership.
// Caller supplies checked presentation and successful, round-tagged I2C polls.
module voice_info_confirm #(
    parameter integer REPLY_TIMEOUT_S = 20,
    parameter integer PROMPT_TIMEOUT_S = 10,
    parameter [7:0] WORD_CORRECT = 8'h04,
    parameter [7:0] WORD_WRONG   = 8'h05,
    parameter [7:0] WORD_REPEAT  = 8'h06
) (
    input wire clk,
    input wire rst,
    input wire tick_1s,
    input wire verified,
    input wire link_ok,
    input wire [31:0] round_id,
    input wire [63:0] info_tag,
    // Assert only after the matching information has actually been presented.
    input wire presented,
    input wire [31:0] presented_round,
    input wire [63:0] presented_tag,
    // Raw successful poll samples, including zero; NOT old word_valid alone.
    input wire sample_valid,
    input wire [31:0] sample_round,
    input wire [63:0] sample_tag,
    input wire [7:0] sample_id,
    // Held request; completion must carry the cookie of the accepted request.
    output wire prompt_valid,
    input wire prompt_ready,
    output wire [7:0] prompt_id,
    output wire [31:0] prompt_cookie,
    input wire prompt_done,
    input wire [31:0] done_cookie,
    input wire prompt_ok,
    output wire start_permit,
    output wire [3:0] state,
    output reg confirmed_pulse
);
    localparam [3:0] IDLE=0, SEND=1, INFLIGHT=2, NEUTRAL=3, REPLY=4,
                     CONFIRMED=5, DENIED=6, TIMED_OUT=7, FAULT=8;
    localparam [7:0] ANN_CHECK=8'h40, ANN_OK=8'h41,
                     ANN_WRONG=8'h42, ANN_TIMEOUT=8'h43;
    reg [3:0] phase, after_prompt;
    reg [31:0] held_round, cookie_counter;
    reg [63:0] held_tag;
    reg [7:0] announcement;
    reg [31:0] seconds;
    reg was_verified;
    wire binding_ok = held_round == round_id && held_tag == info_tag;
    wire presentation_ok = presented && presented_round == round_id &&
                           presented_tag == info_tag;
    wire context_ok = verified && link_ok && binding_ok && presentation_ok;
    wire matching_sample = sample_valid && sample_round == held_round &&
                           sample_tag == held_tag;

    assign state = phase;
    assign prompt_valid = phase == SEND && context_ok;
    assign prompt_id = announcement;
    assign prompt_cookie = cookie_counter;
    assign start_permit = phase == CONFIRMED && context_ok;

    // Called only on a fresh transition; cookie zero is never issued. Saturation
    // fails closed instead of letting an old completion match a new request.
    task queue_prompt;
        input [7:0] id;
        input [3:0] following;
        begin
            seconds <= 0;
            if (cookie_counter == 32'hffffffff) begin
                phase <= FAULT;
            end else begin
                cookie_counter <= cookie_counter + 1'b1;
                announcement <= id;
                after_prompt <= following;
                phase <= SEND;
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            phase <= IDLE;
            after_prompt <= IDLE;
            held_round <= 0;
            held_tag <= 0;
            cookie_counter <= 0;
            announcement <= 0;
            seconds <= 0;
            was_verified <= 0;
            confirmed_pulse <= 0;
        end else begin
            confirmed_pulse <= 0;
            was_verified <= verified;
            // Round and information changes cancel even a held confirmation.
            // They take precedence over a simultaneous sample or completion.
            if (!verified) begin
                phase <= IDLE;
                seconds <= 0;
                held_round <= round_id;
                held_tag <= info_tag;
            end else if (!was_verified || !binding_ok) begin
                phase <= IDLE;
                seconds <= 0;
                held_round <= round_id;
                held_tag <= info_tag;
            end else if (!link_ok || (phase != IDLE && !presentation_ok)) begin
                // Reconnection alone must never reinstate an old permission.
                phase <= FAULT;
                seconds <= 0;
            end else begin
                case (phase)
                    IDLE: if (presentation_ok)
                        queue_prompt(ANN_CHECK, NEUTRAL);
                    SEND, INFLIGHT: begin
                        // Deadline wins if completion and timeout coincide.
                        if (tick_1s && seconds >= PROMPT_TIMEOUT_S-1) begin
                            phase <= FAULT;
                            seconds <= 0;
                        end else begin
                            if (tick_1s) seconds <= seconds + 1'b1;
                            if (phase == SEND && prompt_ready)
                                phase <= INFLIGHT;
                            if (phase == INFLIGHT && prompt_done &&
                                done_cookie == cookie_counter) begin
                                seconds <= 0;
                                phase <= prompt_ok ? after_prompt : FAULT;
                                if (prompt_ok && after_prompt == CONFIRMED)
                                    confirmed_pulse <= 1;
                            end
                        end
                    end
                    NEUTRAL, REPLY: begin
                        if (tick_1s && seconds >= REPLY_TIMEOUT_S-1) begin
                            queue_prompt(ANN_TIMEOUT, TIMED_OUT);
                        end else begin
                            if (tick_1s) seconds <= seconds + 1'b1;
                            // A successful post-prompt zero poll is mandatory.
                            // Unknown words neither confirm nor extend timeout.
                            if (matching_sample) begin
                                if (phase == NEUTRAL) begin
                                    if (sample_id == 0) phase <= REPLY;
                                end else if (sample_id == WORD_CORRECT) begin
                                    queue_prompt(ANN_OK, CONFIRMED);
                                end else if (sample_id == WORD_WRONG) begin
                                    queue_prompt(ANN_WRONG, DENIED);
                                end else if (sample_id == WORD_REPEAT) begin
                                    queue_prompt(ANN_CHECK, NEUTRAL);
                                end
                            end
                        end
                    end
                    CONFIRMED, DENIED, TIMED_OUT, FAULT: begin end
                    default: phase <= FAULT;
                endcase
            end
        end
    end
endmodule
