`timescale 1ns/1ps
////////////////////////////////////////////////////////////////////////////////////
// exam_fsm - ExamGuard exam-flow state machine.
//
//   S_IDLE -> S_WAIT_FACE -> S_VERIFIED -> S_EXAM -> S_SUBMITTED -> S_END
//
// Inputs (single clock domain, pulses supplied by the top):
//   tick_1s      : one-second heartbeat for exam timing
//   frame_pulse  : once per video frame, samples fullscreen activity
//   face_*       : from ai_mailbox (authorisation)
//   object_*     : from ai_mailbox (prohibited object class)
//   activity_*   : from fullscreen_monitor
//   start/submit/ack : operator controls
//
// Only FPGA-deterministic events are generated here; K230 supplies identity
// and object semantics. Event codes follow docs/examguard_final_plan.md §7.
////////////////////////////////////////////////////////////////////////////////////
module exam_fsm #(
    parameter [15:0] EXAM_LEN_S         = 16'd2700, // 45 min
    parameter [3:0]  SELFCHECK_TICKS    = 4'd2,
    parameter [7:0]  LOW_ACT_THRESHOLD  = 8'd4,
    parameter [15:0] LOW_ACT_FRAMES     = 16'd600, // 10 s at 60 frame pulses/s
    // A single frame with this many changed grid cells (out of 80x45=3600) is a
    // sudden scene change (camera covered / large motion).
    parameter [15:0] SPIKE_CELLS        = 16'd1200,
    parameter [7:0]  EVENT_HOLD_TICKS   = 8'd2,
    // Net "gaze off-centre" samples before 0x60 频繁扭头 is reported. The
    // K230 sends one gaze sample per processed frame; frames with no face do
    // not change the count, and centred samples decay it. Lowered to 5 so a
    // head turn alerts quickly.
    parameter [15:0] GAZE_TURN_FRAMES   = 16'd5,
    // Consecutive centred (face present, not turned) samples that re-arm 0x60
    // after it has fired, so each new head turn reports again.
    parameter [3:0]  GAZE_REARM         = 4'd2,
    // Opt-in for the independent transaction-chain lab. Default preserves the
    // examguard14 panel path and its object/video suppression exactly.
    parameter        PARALLEL_EVENTS    = 0,
    parameter        ENABLE_RUNTIME_DURATION = 0,
    parameter        USE_PIXEL_BLACK_GATE = 0
) (
    input             clk,
    input             rst,
    input             tick_1s,
    input             frame_pulse,

    input             face_pulse,
    input             face_ok,
    input      [1:0]  face_id,
    input             object_pulse,
    input      [2:0]  object_class,
    input      [7:0]  activity_global,
    input      [15:0] active_cells,
    input      [7:0]  luma_avg,
    input             camera_covered,

    // Eye-gaze / head-turn samples from ai_mailbox (algorithm 07).
    input             gaze_pulse,
    input             gaze_away,
    input             gaze_present,

    input             start_pulse,
    input             submit_pulse,
    input             ack_pulse,
    // Bench demo: force the timeout path without waiting EXAM_LEN_S.
    input             timeout_pulse,
    input      [15:0] configured_duration_s,

    output reg [2:0]  stage_id,
    output reg [1:0]  risk_level,
    output reg [7:0]  event_code,
    output reg [15:0] event_seq,
    output reg [15:0] remaining_s,
    output reg [1:0]  authorized_id,
    output reg        new_event,
    // Diagnostic snapshot of the inputs used at the last exam frame pulse.
    output reg [7:0]  debug_luma,
    output reg [7:0]  debug_base,
    output reg [7:0]  debug_flags,
    // [GAZE-DIAG] live head-turn accumulator (mirrors gaze_cnt).
    output wire [15:0] debug_gaze_cnt,
    // Registered one-cycle pulses: 0=flow/auth, 1=object, 2=gaze, 3=video.
    // Each 16-bit lane is {reserved, stage[2:0], auth[1:0], risk[1:0], code[7:0]}.
    // These are requests, not proof of queue acceptance or image capture.
    output reg [3:0]   event_request,
    output reg [63:0]  event_request_data
);

    // Stages
    localparam [2:0] S_IDLE = 3'd0, S_WAIT = 3'd1, S_VERIFIED = 3'd2,
                     S_EXAM = 3'd3, S_SUBMITTED = 3'd4, S_END = 3'd5;

    // Risk
    localparam [1:0] RISK_NORMAL = 2'd0, RISK_WARNING = 2'd1,
                     RISK_ALARM  = 2'd2, RISK_SEVERE  = 2'd3;

    // Events
    localparam [7:0] EV_NONE        = 8'h00;
    localparam [7:0] EV_AUTH_OK     = 8'h01;
    localparam [7:0] EV_END_OK      = 8'h03;
    localparam [7:0] EV_NO_VERIFY   = 8'h10;
    localparam [7:0] EV_NOT_AUTH    = 8'h11;
    localparam [7:0] EV_SUBMIT      = 8'h21;
    localparam [7:0] EV_TIMEOUT     = 8'h31;
    localparam [7:0] EV_OBJ_PHONE   = 8'h50;
    localparam [7:0] EV_OBJ_NOTES   = 8'h51;
    localparam [7:0] EV_OBJ_EAR     = 8'h52;
    localparam [7:0] EV_OBJ_WATCH   = 8'h53;
    localparam [7:0] EV_HEAD_TURN   = 8'h60;
    localparam [7:0] EV_CAM_BLOCK   = 8'h64;
    localparam [7:0] EV_STILL       = 8'h65;

    reg [2:0]  state;
    reg [3:0]  selfcheck_cnt;
    reg [7:0]  event_hold;
    reg [15:0] low_cnt;
    reg [3:0] object_seen;
    reg [1:0] object_clear_count;
    reg        spike_active;
    reg [7:0]  luma_base;      // exam brightness reference; never follows dimming
    reg [15:0] gaze_cnt;       // accumulated off-centre gaze samples
    reg        gaze_latched;   // 0x60 already reported for this episode
    reg [3:0]  gaze_centered;  // centred samples seen while latched

    assign debug_gaze_cnt = gaze_cnt;

    // Camera blocked: brightness fell well below the running baseline (covering
    // the lens). Only active once the baseline is established.
    wire dark_now = USE_PIXEL_BLACK_GATE ? camera_covered :
                   ((luma_base > 8'd50) && (luma_avg < (luma_base >> 1)));

    integer display_source;

    task emit;
        input integer source;
        input [7:0] code;
        input [1:0] rsk;
        input [2:0] event_stage;
        input [1:0] event_auth;
        begin
            event_request[source] <= 1'b1;
            event_request_data[source*16 +: 16] <=
                {1'b0, event_stage, event_auth, rsk, code};
            // Legacy event_seq is still a panel-update counter, not a unique
            // transaction ID. In parallel mode flow > object > gaze > video.
            if (!PARALLEL_EVENTS || source < display_source) begin
                event_code <= code;
                risk_level <= rsk;
                event_seq  <= event_seq + 16'd1;
                event_hold <= EVENT_HOLD_TICKS;
                new_event  <= 1'b1;
                display_source = source;
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            state          <= S_IDLE;
            selfcheck_cnt  <= 4'd0;
            event_hold     <= 8'd0;
            low_cnt        <= 16'd0;
            object_seen    <= 4'd0;
            object_clear_count <= 2'd0;
            spike_active   <= 1'b0;
            luma_base      <= 8'd0;
            gaze_cnt       <= 16'd0;
            gaze_latched   <= 1'b0;
            gaze_centered  <= 4'd0;
            stage_id       <= S_IDLE;
            risk_level     <= RISK_NORMAL;
            event_code     <= EV_NONE;
            event_seq      <= 16'd0;
            remaining_s    <= 16'd0;
            authorized_id  <= 2'd0;
            new_event      <= 1'b0;
            debug_luma     <= 8'd0;
            debug_base     <= 8'd0;
            debug_flags    <= 8'd0;
            event_request  <= 4'd0;
            event_request_data <= 64'd0;
        end else begin
            new_event <= 1'b0;
            event_request <= 4'd0;
            event_request_data <= 64'd0;
            display_source = 4;

            // Event auto-clear so the panel returns to NORMAL between events.
            if (tick_1s && event_hold != 8'd0) begin
                if (event_hold == 8'd1) begin
                    event_hold <= 8'd0;
                    event_code <= EV_NONE;
                    risk_level <= RISK_NORMAL;
                end else begin
                    event_hold <= event_hold - 8'd1;
                end
            end

            case (state)
                S_IDLE: begin
                    if (tick_1s) begin
                        if ((selfcheck_cnt + 4'd1) >= SELFCHECK_TICKS) begin
                            selfcheck_cnt <= 4'd0;
                            state    <= S_WAIT;
                            stage_id <= S_WAIT;
                        end else begin
                            selfcheck_cnt <= selfcheck_cnt + 4'd1;
                        end
                    end
                end

                S_WAIT: begin
                    if (face_pulse) begin
                        if (face_ok) begin
                            authorized_id <= face_id;
                            emit(0, EV_AUTH_OK, RISK_NORMAL, S_VERIFIED, face_id);
                            state    <= S_VERIFIED;
                            stage_id <= S_VERIFIED;
                        end else begin
                            authorized_id <= 2'd0;
                            emit(0, EV_NOT_AUTH, RISK_ALARM, S_WAIT, 2'd0);
                        end
                    end else if (start_pulse && (authorized_id == 2'd0)) begin
                        emit(0, EV_NO_VERIFY, RISK_ALARM, S_WAIT, authorized_id);
                    end
                end

                S_VERIFIED: begin
                    if (start_pulse) begin
                        state       <= S_EXAM;
                        stage_id    <= S_EXAM;
                        remaining_s <= ENABLE_RUNTIME_DURATION ? configured_duration_s : EXAM_LEN_S;
                        low_cnt     <= 16'd0;
                        object_seen <= 4'd0;
                        object_clear_count <= 2'd0;
                        spike_active<= 1'b0;
                        luma_base   <= 8'd0;
                        gaze_cnt    <= 16'd0;
                        gaze_latched<= 1'b0;
                        gaze_centered <= 4'd0;
                    end
                end

                S_EXAM: begin
                    // Prohibited object (K230 ID 14 classification).
                    if (object_pulse) begin
                        // Silence never means absence. Three consecutive explicit
                        // NONE results rearm all classes; other labels interrupt.
                        if (object_class == 3'd7) begin
                            if (object_clear_count == 2'd2) begin
                                object_seen <= 4'd0;
                                object_clear_count <= 2'd0;
                            end else object_clear_count <= object_clear_count + 1'b1;
                        end else begin
                            object_clear_count <= 2'd0;
                            if (object_class >= 3'd1 && object_class <= 3'd4) begin
                                object_seen[object_class - 1'b1] <= 1'b1;
                                if (!object_seen[object_class - 1'b1]) begin
                        case (object_class)
                            3'd1: emit(1, EV_OBJ_PHONE, RISK_SEVERE, S_EXAM, authorized_id);
                            3'd2: emit(1, EV_OBJ_NOTES, RISK_SEVERE, S_EXAM, authorized_id);
                            3'd3: emit(1, EV_OBJ_EAR,   RISK_SEVERE, S_EXAM, authorized_id);
                            3'd4: emit(1, EV_OBJ_WATCH, RISK_SEVERE, S_EXAM, authorized_id);
                            default: ; // other objects are not violations
                        endcase
                                end
                            end
                        end
                    end

                    // Head turn / gaze off-screen (K230 ID 07). Sustained
                    // off-centre gaze for GAZE_TURN_FRAMES samples -> 0x60,
                    // once per episode; re-arms after returning to centre.
                    if (gaze_pulse) begin
                        if (gaze_away) begin
                            gaze_centered <= 4'd0;
                            if (gaze_cnt < GAZE_TURN_FRAMES)
                                gaze_cnt <= gaze_cnt + 16'd1;
                            if ((gaze_cnt + 16'd1 >= GAZE_TURN_FRAMES) && !gaze_latched) begin
                                emit(2, EV_HEAD_TURN, RISK_ALARM, S_EXAM, authorized_id);
                                gaze_latched <= 1'b1;
                            end
                        end else if (gaze_present) begin
                            if (gaze_latched) begin
                                // Re-arm after a short centred spell, so the next
                                // head turn reports again.
                                if (gaze_centered + 4'd1 >= GAZE_REARM) begin
                                    gaze_latched  <= 1'b0;
                                    gaze_cnt      <= 16'd0;
                                    gaze_centered <= 4'd0;
                                end else begin
                                    gaze_centered <= gaze_centered + 4'd1;
                                end
                            end else if (gaze_cnt != 16'd0) begin
                                gaze_cnt <= gaze_cnt - 16'd1;
                            end
                        end
                        // no face -> freeze counters
                    end
                    // No face -> freeze the counter (do not decay), so an
                    // intermittent detector cannot reset a head turn.

                    // Fullscreen activity: camera blocked (single-frame spike in
                    // the raw changed-cell count) / abnormal stillness (low
                    // smoothed activity sustained over many frames).
                    // New severe object takes priority over a coincident video
                    // sample, otherwise that sample could overwrite its event.
                    if (frame_pulse && (PARALLEL_EVENTS || !(object_pulse && object_class >= 3'd1 &&
                        object_class <= 3'd4 && !object_seen[object_class - 1'b1]))) begin
                        // [DEBUG-cover] bits: 0=dark_now, 1=cell spike,
                        // 2=episode active before frame, 3=reference > 50,
                        // 4=event was 64, 5=hold nonzero, 6=1s tick, 7=marker.
                        debug_luma <= luma_avg;
                        debug_base <= luma_base;
                        debug_flags <= {1'b1, tick_1s, (event_hold != 0),
                                        (event_code == EV_CAM_BLOCK),
                                        (luma_base > 8'd50), spike_active,
                                        (active_cells >= SPIKE_CELLS), dark_now};
                        // Establish a reference after entering the exam. Track
                        // brighter scenes slowly, but never learn a gradual
                        // cover as the new normal. Independent of motion.
                        if (luma_base == 8'd0)
                            luma_base <= luma_avg;
                        else if (luma_avg > luma_base)
                            luma_base <= luma_base + ((luma_avg - luma_base) >> 4);

                        // Camera blocked (brightness collapse) OR a per-frame
                        // scene spike -> 0x64, once per episode.
                        if (dark_now || (!USE_PIXEL_BLACK_GATE && (active_cells >= SPIKE_CELLS))) begin
                            if (!spike_active) begin
                                spike_active <= 1'b1;
                                emit(3, EV_CAM_BLOCK, RISK_WARNING, S_EXAM, authorized_id);
                            end else if (dark_now && event_code == EV_CAM_BLOCK &&
                                         (!PARALLEL_EVENTS || display_source == 4)) begin
                                // Keep a stationary covered image in violation,
                                // without counting a fresh event every frame.
                                event_code <= EV_CAM_BLOCK;
                                risk_level <= RISK_WARNING;
                                event_hold <= EVENT_HOLD_TICKS;
                            end
                            low_cnt <= 16'd0;
                        end else begin
                            spike_active <= 1'b0;
                            if (activity_global <= LOW_ACT_THRESHOLD) begin
                                if ((low_cnt + 16'd1) >= LOW_ACT_FRAMES) begin
                                    low_cnt <= 16'd0;
                                    emit(3, EV_STILL, RISK_WARNING, S_EXAM, authorized_id);
                                end else begin
                                    low_cnt <= low_cnt + 16'd1;
                                end
                            end else begin
                                low_cnt <= 16'd0;
                            end
                        end
                    end

                    // Timing / submission.
                    if (submit_pulse) begin
                        emit(0, EV_SUBMIT, RISK_NORMAL, S_SUBMITTED, authorized_id);
                        state    <= S_SUBMITTED;
                        stage_id <= S_SUBMITTED;
                    end else if (timeout_pulse) begin
                        remaining_s <= 16'd0;
                        emit(0, EV_TIMEOUT, RISK_WARNING, S_SUBMITTED, authorized_id);
                        state    <= S_SUBMITTED;
                        stage_id <= S_SUBMITTED;
                    end else if (tick_1s) begin
                        if (remaining_s <= 16'd1) begin
                            remaining_s <= 16'd0;
                            emit(0, EV_TIMEOUT, RISK_WARNING, S_SUBMITTED, authorized_id);
                            state    <= S_SUBMITTED;
                            stage_id <= S_SUBMITTED;
                        end else begin
                            remaining_s <= remaining_s - 16'd1;
                        end
                    end
                end

                S_SUBMITTED: begin
                    if (ack_pulse) begin
                        emit(0, EV_END_OK, RISK_NORMAL, S_END, authorized_id);
                        state    <= S_END;
                        stage_id <= S_END;
                    end
                end

                S_END: begin
                    // Terminal.
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
