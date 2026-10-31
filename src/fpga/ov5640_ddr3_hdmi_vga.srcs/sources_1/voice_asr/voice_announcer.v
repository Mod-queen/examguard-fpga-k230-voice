`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// ExamGuard voice guide: turns exam stages and events into WonderEcho TTS
// announcements (the FPGA writes the announcement register, no wake word).
//
// stage_id arrives from the exam FSM through the status mailbox (50 MHz). On
// every stage change this speaks the next step of the flow, so the prompt itself
// walks the candidate through: 自检 -> 候考 -> 核验 -> 考试 -> 交卷 -> 结束.
// During the exam, mapped events (auth failure, prohibited object, head turn,
// camera blocked, stillness) also speak one prompt per episode, in step with the
// buzzer.
//
// Announcement IDs are a standalone ExamGuard set (0x20..0x3F); they do NOT
// reuse the retired ProcessGuard IDs (0x10..0x14). Type 0xFF = general
// announcement. Word list: docs/wonderecho/examguard_voice.md
// -----------------------------------------------------------------------------
module voice_announcer #(
    // Stage guide (spoken once per stage entry)
    parameter [7:0] ANN_IDLE      = 8'h20, // S_IDLE      system self-check
    parameter [7:0] ANN_WAIT      = 8'h21, // S_WAIT      show face to verify
    parameter [7:0] ANN_VERIFIED  = 8'h22, // S_VERIFIED  verified, be seated
    parameter [7:0] ANN_EXAM      = 8'h23, // S_EXAM      exam begins
    parameter [7:0] ANN_SUBMITTED = 8'h24, // S_SUBMITTED paper collected
    parameter [7:0] ANN_END       = 8'h25, // S_END       exam over
    parameter [7:0] ANN_TIMEOUT   = 8'h26, // S_SUBMITTED entered by timeout
    // Event prompts (spoken once per episode)
    parameter [7:0] ANN_NO_VERIFY = 8'h30, // 0x10 entered without verifying
    parameter [7:0] ANN_NOT_AUTH  = 8'h31, // 0x11 not an authorized person
    parameter [7:0] ANN_PHONE     = 8'h32, // 0x50 phone
    parameter [7:0] ANN_NOTES     = 8'h33, // 0x51 notes/material
    parameter [7:0] ANN_HEAD_TURN = 8'h36, // 0x60 head turn
    parameter [7:0] ANN_CAM_BLOCK = 8'h37, // 0x64 camera blocked
    parameter [7:0] ANN_STILL     = 8'h38  // 0x65 abnormal stillness
) (
    input         clk,
    input         rst,
    input         valid,        // status snapshot strobe (one clk in 50 MHz)
    input  [2:0]  stage_id,     // exam FSM stage (via status mailbox)
    input  [7:0]  event_code,
    input  [7:0]  event_seq,
    output reg        tts_req,
    output reg [7:0]  tts_type,
    output reg [7:0]  tts_id
);

    localparam [7:0] TYPE_ANNOUNCE = 8'hFF;

    localparam [2:0] S_IDLE = 3'd0, S_WAIT = 3'd1, S_VERIFIED = 3'd2,
                     S_EXAM = 3'd3, S_SUBMITTED = 3'd4, S_END = 3'd5;

    localparam [7:0] EV_NONE      = 8'h00;
    localparam [7:0] EV_NO_VERIFY = 8'h10;
    localparam [7:0] EV_NOT_AUTH  = 8'h11;
    localparam [7:0] EV_TIMEOUT   = 8'h31;
    localparam [7:0] EV_PHONE     = 8'h50;
    localparam [7:0] EV_NOTES     = 8'h51;
    localparam [7:0] EV_HEAD_TURN = 8'h60;
    localparam [7:0] EV_CAM_BLOCK = 8'h64;
    localparam [7:0] EV_STILL     = 8'h65;

    reg [2:0] last_stage;
    reg [7:0] last_seq;
    reg       started;

    always @(posedge clk) begin
        if (rst) begin
            tts_req    <= 1'b0;
            tts_type   <= 8'h00;
            tts_id     <= 8'h00;
            last_stage <= 3'd7;
            last_seq   <= 8'd0;
            started    <= 1'b0;
        end else begin
            tts_req <= 1'b0;

            if (valid) begin
                if (!started || (stage_id != last_stage)) begin
                    // A stage change is the step-by-step guide. A co-timed
                    // event is consumed so it does not also speak (0x01 with
                    // S_VERIFIED, 0x21/0x03 with their stages).
                    started    <= 1'b1;
                    last_stage <= stage_id;
                    last_seq   <= event_seq;
                    tts_req    <= 1'b1;
                    tts_type   <= TYPE_ANNOUNCE;
                    case (stage_id)
                        S_IDLE:      tts_id <= ANN_IDLE;
                        S_WAIT:      tts_id <= ANN_WAIT;
                        S_VERIFIED:  tts_id <= ANN_VERIFIED;
                        S_EXAM:      tts_id <= ANN_EXAM;
                        S_SUBMITTED: tts_id <= (event_code == EV_TIMEOUT) ? ANN_TIMEOUT
                                                                          : ANN_SUBMITTED;
                        S_END:       tts_id <= ANN_END;
                        default: begin
                            tts_req <= 1'b0;
                            tts_id  <= 8'h00;
                        end
                    endcase
                end else if ((event_code != EV_NONE) && (event_seq != last_seq)) begin
                    last_seq <= event_seq;
                    tts_req  <= 1'b1;
                    tts_type <= TYPE_ANNOUNCE;
                    case (event_code)
                        EV_NO_VERIFY: tts_id <= ANN_NO_VERIFY;
                        EV_NOT_AUTH:  tts_id <= ANN_NOT_AUTH;
                        EV_PHONE:     tts_id <= ANN_PHONE;
                        EV_NOTES:     tts_id <= ANN_NOTES;
                        EV_HEAD_TURN: tts_id <= ANN_HEAD_TURN;
                        EV_CAM_BLOCK: tts_id <= ANN_CAM_BLOCK;
                        EV_STILL:     tts_id <= ANN_STILL;
                        default: begin
                            tts_id  <= 8'h00;
                            tts_req <= 1'b0;
                        end
                    endcase
                end
            end
        end
    end

endmodule
