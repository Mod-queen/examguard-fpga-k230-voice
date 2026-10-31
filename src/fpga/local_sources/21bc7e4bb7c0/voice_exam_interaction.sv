`timescale 1ns/1ps

// Independent candidate: S3 authorises preparation, READY releases one actual
// exam_fsm start pulse. Help is an independent held ticket, never an exam event.
module voice_exam_interaction #(
    parameter integer REPLY_TIMEOUT_S = 30,
    parameter integer PROMPT_TIMEOUT_S = 10,
    // Compact candidate: readiness is visible on PC; actual stage3 speaks FF23.
    // Keep 1 for compatibility with the independently verified original flow.
    parameter integer READY_FEEDBACK = 1,
    parameter [7:0] WORD_READY = 8'h07,
    parameter [7:0] WORD_HELP = 8'h08,
    parameter [7:0] WORD_REPEAT = 8'h06
) (
    input wire clk,
    input wire rst,
    input wire tick_1s,
    input wire [2:0] exam_stage,
    input wire info_permit,
    input wire start_blocked, // persistent/maintenance admission, applied live
    input wire s3_pulse,      // debounced physical key only
    input wire link_ok,       // voice AND PC status/ack link freshness
    input wire [31:0] round_id,
    input wire [63:0] info_tag,
    input wire sample_valid,
    input wire [31:0] sample_round,
    input wire [63:0] sample_tag,
    input wire [7:0] sample_id,
    output wire prompt_valid,
    input wire prompt_ready,
    output wire [7:0] prompt_id,
    output wire [31:0] prompt_cookie,
    input wire prompt_done,
    input wire [31:0] done_cookie,
    input wire prompt_ok,
    // PC sees a level plus identity, acknowledges the exact handled ticket.
    output reg help_pending,
    output reg [31:0] help_ticket,
    output reg help_in_exam,
    output reg [31:0] help_round,
    output reg [63:0] help_tag,
    input wire help_handled,
    input wire [31:0] handled_round,
    input wire [63:0] handled_tag,
    input wire [31:0] handled_ticket,
    output wire exam_start_pulse,
    output reg ready_recorded,
    output wire [3:0] state
);
    localparam [3:0] IDLE=0, SEND=1, INFLIGHT=2, NEUTRAL=3, REPLY=4,
                     COMMIT=5, WAIT_EXAM=6, ACTIVE=7, EXAM_NEUTRAL=8,
                     TIMED_OUT=9, FAULT=10, ENDED=11;
    localparam [7:0] ANN_PREP=8'h44, ANN_READY=8'h45,
                     ANN_PREP_HELP=8'h46, ANN_EXAM_HELP=8'h47,
                     ANN_NO_REPLY=8'h48;
    reg [3:0] phase, following;
    reg [31:0] bound_round, cookie_counter, seconds;
    reg [63:0] bound_tag;
    reg [7:0] announcement;
    reg attempt_live, origin_exam;
    wire binding_ok = bound_round == round_id && bound_tag == info_tag;
    wire pre_context = exam_stage == 2 && info_permit;
    wire matching_sample = sample_valid && sample_round == bound_round &&
                           sample_tag == bound_tag;
    wire matching_handled = help_handled && help_pending &&
                            handled_round == bound_round &&
                            handled_tag == bound_tag && handled_ticket == help_ticket;
    wire context_ok = binding_ok && link_ok &&
                      (origin_exam ? exam_stage == 3 : pre_context);

    assign state = phase;
    assign prompt_valid = phase == SEND && context_ok;
    assign prompt_id = announcement;
    assign prompt_cookie = cookie_counter;
    // Live gate: no registered stale pulse may bypass maintenance or info loss.
    assign exam_start_pulse = phase == COMMIT && context_ok &&
                              !start_blocked && !help_pending && ready_recorded;

    task queue_prompt;
        input [7:0] id;
        input [3:0] next_phase;
        begin
            seconds <= 0;
            if (cookie_counter == 32'hffffffff) phase <= FAULT;
            else begin
                cookie_counter <= cookie_counter + 1'b1;
                announcement <= id;
                following <= next_phase;
                phase <= SEND;
            end
        end
    endtask

    task request_help;
        input during_exam;
        begin
            if (help_ticket == 32'hffffffff) phase <= FAULT;
            else begin
                help_ticket <= help_ticket + 1'b1;
                help_pending <= 1;
                help_in_exam <= during_exam;
                help_round <= bound_round;
                help_tag <= bound_tag;
                queue_prompt(during_exam ? ANN_EXAM_HELP : ANN_PREP_HELP,
                             during_exam ? EXAM_NEUTRAL : NEUTRAL);
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            phase <= IDLE; following <= IDLE;
            bound_round <= 0; bound_tag <= 0;
            cookie_counter <= 0; seconds <= 0; announcement <= 0;
            help_pending <= 0; help_ticket <= 0; help_in_exam <= 0;
            help_round <= 0; help_tag <= 0;
            attempt_live <= 0; origin_exam <= 0; ready_recorded <= 0;
        end else if (!binding_ok) begin
            // Old PC ticket remains in host history; new context cannot clear it.
            bound_round <= round_id; bound_tag <= info_tag;
            phase <= IDLE; seconds <= 0; help_pending <= 0;
            attempt_live <= 0; origin_exam <= 0; ready_recorded <= 0;
            // Cookie and ticket counters never restart on a new round.
        end else begin
            if (matching_handled && link_ok) help_pending <= 0;
            if (attempt_live && exam_stage != 2 && exam_stage != 3) begin
                // Finishing the exam leaves unresolved help visible to the PC.
                phase <= ENDED; attempt_live <= 0; seconds <= 0;
            end else if (attempt_live && !link_ok) begin
                // This disables interaction only. It never pauses the exam FSM.
                phase <= FAULT;
            end else if (attempt_live && exam_stage == 2 && !info_permit) begin
                phase <= FAULT;
            end else begin
                case (phase)
                    IDLE, TIMED_OUT: begin
                        if (s3_pulse && pre_context && link_ok && !start_blocked &&
                            !help_pending) begin
                            origin_exam <= 0; attempt_live <= 1;
                            ready_recorded <= 0;
                            queue_prompt(ANN_PREP, NEUTRAL);
                        end
                    end
                    SEND, INFLIGHT: begin
                        if (!context_ok) phase <= FAULT;
                        else if (tick_1s && seconds >= PROMPT_TIMEOUT_S-1) begin
                            phase <= FAULT; seconds <= 0;
                        end else begin
                            if (tick_1s) seconds <= seconds + 1'b1;
                            if (phase == SEND && prompt_ready) phase <= INFLIGHT;
                            if (phase == INFLIGHT && prompt_done &&
                                done_cookie == cookie_counter) begin
                                seconds <= 0;
                                phase <= prompt_ok ? following : FAULT;
                            end
                        end
                    end
                    NEUTRAL, REPLY: begin
                        // While help is pending, wait for the teacher without
                        // periodically asking again or declaring candidate ready.
                        if (tick_1s && !help_pending && seconds >= REPLY_TIMEOUT_S-1)
                            queue_prompt(ANN_NO_REPLY, TIMED_OUT);
                        else if (matching_handled && link_ok) begin
                            seconds <= 0; phase <= NEUTRAL;
                        end else begin
                            if (tick_1s && !help_pending) seconds <= seconds + 1'b1;
                            if (matching_sample) begin
                                if (phase == NEUTRAL) begin
                                    if (sample_id == 0) phase <= REPLY;
                                 end else if (sample_id == WORD_READY && !help_pending) begin
                                     ready_recorded <= 1;
                                     if (READY_FEEDBACK) queue_prompt(ANN_READY, COMMIT);
                                     else begin phase <= COMMIT; seconds <= 0; end
                                end else if (sample_id == WORD_HELP && !help_pending)
                                    request_help(0);
                                else if (sample_id == WORD_REPEAT)
                                    queue_prompt(ANN_PREP, NEUTRAL);
                            end
                        end
                    end
                    COMMIT: begin
                        if (!context_ok) phase <= FAULT;
                        else if (tick_1s && seconds >= PROMPT_TIMEOUT_S-1) begin
                            phase <= FAULT; seconds <= 0;
                        end else if (exam_start_pulse) begin
                            phase <= WAIT_EXAM; seconds <= 0;
                        end else if (tick_1s) seconds <= seconds + 1'b1;
                    end
                    WAIT_EXAM: begin
                        if (exam_stage == 3) begin
                            origin_exam <= 1; phase <= EXAM_NEUTRAL; seconds <= 0;
                        end else if (tick_1s && seconds >= PROMPT_TIMEOUT_S-1) begin
                            phase <= FAULT; seconds <= 0;
                        end else if (tick_1s) seconds <= seconds + 1'b1;
                    end
                    EXAM_NEUTRAL: begin
                        if (exam_stage != 3) phase <= FAULT;
                        else if (matching_sample && sample_id == 0) phase <= ACTIVE;
                    end
                    ACTIVE: begin
                        if (exam_stage != 3) phase <= FAULT;
                        else if (matching_handled && link_ok) phase <= EXAM_NEUTRAL;
                        else if (matching_sample && sample_id == WORD_HELP && !help_pending)
                            request_help(1);
                    end
                    FAULT, ENDED: begin end
                    default: phase <= FAULT;
                endcase
            end
        end
    end
endmodule
