`timescale 1ns/1ps
////////////////////////////////////////////////////////////////////////////////////
// exam_fsm_tb - directed test of the exam flow and event codes.
////////////////////////////////////////////////////////////////////////////////////
module exam_fsm_tb;

    reg         clk = 1'b0;
    reg         rst = 1'b1;
    reg         tick_1s = 1'b0;
    reg         frame_pulse = 1'b0;
    reg         face_pulse = 1'b0;
    reg         face_ok = 1'b0;
    reg  [1:0]  face_id = 2'd0;
    reg         object_pulse = 1'b0;
    reg  [2:0]  object_class = 3'd0;
    reg  [7:0]  activity_global = 8'd0;
    reg  [15:0] active_cells = 16'd0;
    reg  [7:0]  luma_avg = 8'd0;
    reg         gaze_pulse = 1'b0;
    reg         gaze_away = 1'b0;
    reg         gaze_present = 1'b0;
    reg         start_pulse = 1'b0;
    reg         submit_pulse = 1'b0;
    reg         ack_pulse = 1'b0;
    reg         timeout_pulse = 1'b0;

    wire [2:0]  stage_id;
    wire [1:0]  risk_level;
    wire [7:0]  event_code;
    wire [15:0] event_seq;
    wire [15:0] remaining_s;
    wire [1:0]  authorized_id;
    wire        new_event;
    wire [7:0] debug_luma, debug_base, debug_flags;
    integer lum_step;
    reg [15:0] saved_seq;

    always #5 clk = ~clk;

    exam_fsm #(
        .EXAM_LEN_S         (16'd5),
        .SELFCHECK_TICKS    (4'd2),
        .LOW_ACT_THRESHOLD  (8'd4),
        .LOW_ACT_FRAMES     (16'd3),
        .SPIKE_CELLS        (16'd1200),
        .EVENT_HOLD_TICKS   (8'd2),
        .GAZE_TURN_FRAMES   (16'd3)
    ) dut (
        .clk(clk), .rst(rst),
        .tick_1s(tick_1s), .frame_pulse(frame_pulse),
        .face_pulse(face_pulse), .face_ok(face_ok), .face_id(face_id),
        .object_pulse(object_pulse), .object_class(object_class),
        .activity_global(activity_global),
        .active_cells(active_cells),
        .luma_avg(luma_avg),
        .gaze_pulse(gaze_pulse), .gaze_away(gaze_away), .gaze_present(gaze_present),
        .start_pulse(start_pulse), .submit_pulse(submit_pulse), .ack_pulse(ack_pulse),
        .timeout_pulse(timeout_pulse),
        .stage_id(stage_id), .risk_level(risk_level), .event_code(event_code),
        .event_seq(event_seq), .remaining_s(remaining_s), .authorized_id(authorized_id),
        .new_event(new_event),
        .debug_luma(debug_luma), .debug_base(debug_base), .debug_flags(debug_flags)
    );

    task do_reset;
        begin
            rst = 1'b1;
            repeat (3) @(negedge clk);
            rst = 1'b0;
            @(negedge clk);
        end
    endtask

    task pulse_tick;
        begin @(negedge clk); tick_1s = 1'b1; @(negedge clk); tick_1s = 1'b0; @(negedge clk); end
    endtask

    task pulse_face;
        input ok; input [1:0] id;
        begin @(negedge clk); face_pulse = 1'b1; face_ok = ok; face_id = id;
              @(negedge clk); face_pulse = 1'b0; @(negedge clk); end
    endtask

    task pulse_obj;
        input [2:0] c;
        begin @(negedge clk); object_pulse = 1'b1; object_class = c;
              @(negedge clk); object_pulse = 1'b0; @(negedge clk); end
    endtask

    task pulse_frame;
        input [7:0]  act;
        input [15:0] cells;
        input [7:0]  lum;
        begin @(negedge clk); frame_pulse = 1'b1; activity_global = act; active_cells = cells; luma_avg = lum;
              @(negedge clk); frame_pulse = 1'b0; @(negedge clk); end
    endtask

    task pulse_gaze;
        input away;
        input present;
        begin @(negedge clk); gaze_pulse = 1'b1; gaze_away = away; gaze_present = present;
              @(negedge clk); gaze_pulse = 1'b0; @(negedge clk); end
    endtask

    task pulse_start;  begin @(negedge clk); start_pulse = 1'b1;  @(negedge clk); start_pulse = 1'b0;  @(negedge clk); end endtask
    task pulse_submit; begin @(negedge clk); submit_pulse = 1'b1; @(negedge clk); submit_pulse = 1'b0; @(negedge clk); end endtask
    task pulse_ack;    begin @(negedge clk); ack_pulse = 1'b1;    @(negedge clk); ack_pulse = 1'b0;    @(negedge clk); end endtask
    task pulse_timeout; begin @(negedge clk); timeout_pulse = 1'b1; @(negedge clk); timeout_pulse = 1'b0; @(negedge clk); end endtask

    initial begin
        do_reset;

        // Self-check to WAIT.
        pulse_tick;
        pulse_tick;
        if (stage_id !== 3'd1) begin $display("FAIL: not WAIT (%0d)", stage_id); $finish; end

        // Authorised face.
        pulse_face(1'b1, 2'd1);
        if (stage_id !== 3'd2 || event_code !== 8'h01 || authorized_id !== 2'd1) begin
            $display("FAIL: auth ok stage=%0d ev=%02h id=%0d", stage_id, event_code, authorized_id); $finish;
        end

        // Start exam.
        pulse_start;
        if (stage_id !== 3'd3 || remaining_s !== 16'd5) begin
            $display("FAIL: exam not started stage=%0d rem=%0d", stage_id, remaining_s); $finish;
        end

        // Prohibited object -> 0x50 severe.
        pulse_obj(3'd1);
        if (event_code !== 8'h50 || risk_level !== 2'd3) begin
            $display("FAIL: object event=%02h risk=%0d", event_code, risk_level); $finish;
        end

        // Establish a bright baseline, then stillness -> 0x65.
        saved_seq = event_seq;
        repeat (20) pulse_obj(3'd1);
        if (event_seq !== saved_seq) $fatal(1, "persistent phone duplicated");
        pulse_obj(3'd7); pulse_obj(3'd7); pulse_obj(3'd1);
        if (event_seq !== saved_seq) $fatal(1, "short absence rearmed");
        pulse_obj(3'd7); pulse_obj(3'd0); pulse_obj(3'd7); pulse_obj(3'd7);
        pulse_obj(3'd1);
        if (event_seq !== saved_seq) $fatal(1, "other label counted as absence");
        pulse_obj(3'd2);
        if (event_seq !== saved_seq + 1 || event_code !== 8'h51)
            $fatal(1, "different class not emitted");
        saved_seq = event_seq;
        pulse_obj(3'd1); pulse_obj(3'd2);
        if (event_seq !== saved_seq) $fatal(1, "alternating classes duplicated");
        pulse_obj(3'd7); pulse_obj(3'd7); pulse_obj(3'd7);
        @(negedge clk);
        object_pulse = 1; object_class = 1;
        frame_pulse = 1; active_cells = 2000; luma_avg = 120;
        @(negedge clk); object_pulse = 0; frame_pulse = 0; active_cells = 0;
        @(negedge clk);
        if (event_seq !== saved_seq + 1 || event_code !== 8'h50)
            $fatal(1, "rearmed phone lost to concurrent video");

        // Establish a bright baseline, then stillness -> 0x65.
        pulse_frame(8'd0, 16'd0, 8'd120);
        pulse_frame(8'd0, 16'd0, 8'd120);
        pulse_frame(8'd0, 16'd0, 8'd120);
        if (event_code !== 8'h65) begin $display("FAIL: stillness ev=%02h", event_code); $finish; end

        // Sudden scene change -> 0x64 (raw cell spike).
        pulse_frame(8'd0, 16'd2000, 8'd120);
        if (event_code !== 8'h64) begin $display("FAIL: spike ev=%02h", event_code); $finish; end

        // Submit early -> 0x21.
        pulse_submit;
        if (stage_id !== 3'd4 || event_code !== 8'h21) begin
            $display("FAIL: submit stage=%0d ev=%02h", stage_id, event_code); $finish;
        end

        // Acknowledge -> normal end 0x03.
        pulse_ack;
        if (stage_id !== 3'd5 || event_code !== 8'h03) begin
            $display("FAIL: end stage=%0d ev=%02h", stage_id, event_code); $finish;
        end

        // ---- Unauthorised path ----
        do_reset;
        pulse_tick; pulse_tick;
        pulse_face(1'b0, 2'd0);
        if (event_code !== 8'h11 || authorized_id !== 2'd0) begin
            $display("FAIL: not-auth ev=%02h id=%0d", event_code, authorized_id); $finish;
        end
        pulse_start;
        if (event_code !== 8'h10) begin $display("FAIL: no-verify ev=%02h", event_code); $finish; end

        // ---- Timeout path ----
        do_reset;
        pulse_tick; pulse_tick;
        pulse_face(1'b1, 2'd2);
        pulse_start;
        pulse_tick; pulse_tick; pulse_tick; pulse_tick;
        // remaining 5 -> after 4 ticks it is 1; next tick triggers timeout
        pulse_tick;
        if (event_code !== 8'h31 || stage_id !== 3'd4) begin
            $display("FAIL: timeout ev=%02h stage=%0d", event_code, stage_id); $finish;
        end

        // ---- S4 forced-timeout path (bench demo) ----
        do_reset;
        pulse_tick; pulse_tick;
        pulse_face(1'b1, 2'd2);
        pulse_start;
        saved_seq = event_seq;
        pulse_timeout;
        if (event_code !== 8'h31 || stage_id !== 3'd4 ||
            remaining_s !== 16'd0 || event_seq !== saved_seq + 16'd1) begin
            $display("FAIL: forced timeout ev=%02h stage=%0d rem=%0d",
                     event_code, stage_id, remaining_s);
            $finish;
        end

        // ---- Camera-block path (brightness collapse) ----
        do_reset;
        pulse_tick; pulse_tick;
        pulse_face(1'b1, 2'd1);
        pulse_start;
        pulse_frame(8'd0, 16'd0, 8'd120);   // establish baseline
        pulse_frame(8'd0, 16'd0, 8'd0);     // lens covered -> dark
        if (event_code !== 8'h64) begin $display("FAIL: camera block ev=%02h", event_code); $finish; end

        // Slow dimming with NO changed cells must not drag down the reference.
        do_reset;
        pulse_tick; pulse_tick;
        pulse_face(1'b1, 2'd1);
        pulse_start;
        pulse_frame(8'd10, 16'd0, 8'd120);
        saved_seq = event_seq;
        for (lum_step = 119; lum_step >= 60; lum_step = lum_step - 1)
            pulse_frame(8'd10, 16'd0, lum_step);
        if (event_seq !== saved_seq) $fatal(1, "moderate dimming triggered event");
        pulse_frame(8'd0, 16'd0, 8'd59);
        if (debug_luma !== 8'd59 || debug_base !== 8'd120 ||
            debug_flags[3:0] !== 4'b1001 || debug_flags[7] !== 1'b1)
            $fatal(1, "diagnostic snapshot does not match decision inputs");
        if (event_code !== 8'h64 || event_seq !== saved_seq + 16'd1)
            $fatal(1, "slow dimming without motion missed");
        saved_seq = event_seq;
        // The image stays dark and stationary beyond the normal event hold.
        repeat (3) begin
            pulse_tick;
            pulse_frame(8'd0, 16'd0, 8'd20);
        end
        if (event_code !== 8'h64 || event_seq !== saved_seq)
            $fatal(1, "stationary darkness cleared or duplicated event");
        if (debug_luma !== 8'd20 || debug_base !== 8'd120 ||
            debug_flags[5:0] !== 6'b111101)
            $fatal(1, "diagnostic dark hold flags incorrect");
        // Recover and cover again: a new episode, exactly one new sequence.
        pulse_frame(8'd10, 16'd0, 8'd120);
        if (debug_flags[0] !== 1'b0 || debug_luma !== 8'd120)
            $fatal(1, "diagnostic recovery flag incorrect");
        pulse_frame(8'd0, 16'd0, 8'd20);
        if (event_code !== 8'h64 || event_seq !== saved_seq + 16'd1)
            $fatal(1, "dark episode did not rearm");

        // A scene that starts dim is not a brightness DROP.
        do_reset;
        pulse_tick; pulse_tick;
        pulse_face(1'b1, 2'd1);
        pulse_start;
        saved_seq = event_seq;
        repeat (10) pulse_frame(8'd10, 16'd0, 8'd40);
        if (event_seq !== saved_seq) $fatal(1, "dim baseline false alarm");

        // ---- Head-turn / gaze path -> 0x60 ----
        do_reset;
        pulse_tick; pulse_tick;
        pulse_face(1'b1, 2'd1);
        pulse_start;
        saved_seq = event_seq;
        pulse_gaze(1'b1, 1'b1);                 // away #1
        pulse_gaze(1'b0, 1'b0); pulse_gaze(1'b0, 1'b0);   // no face: must not decay
        if (event_seq !== saved_seq) $fatal(1, "no-face frame decayed or fired");
        pulse_gaze(1'b1, 1'b1);                 // away #2
        if (event_seq !== saved_seq) $fatal(1, "head turn reported too early");
        pulse_gaze(1'b1, 1'b1);                 // away #3 -> emit
        if (event_code !== 8'h60 || risk_level !== 2'd2 ||
            event_seq !== saved_seq + 16'd1)
            $fatal(1, "head turn 0x60 not reported");
        saved_seq = event_seq;
        pulse_gaze(1'b1, 1'b1); pulse_gaze(1'b1, 1'b1); pulse_gaze(1'b1, 1'b1);
        if (event_seq !== saved_seq) $fatal(1, "head turn duplicated while latched");
        repeat (2) pulse_gaze(1'b0, 1'b1);      // return to centre re-arms
        pulse_gaze(1'b1, 1'b1); pulse_gaze(1'b1, 1'b1); pulse_gaze(1'b1, 1'b1);
        if (event_code !== 8'h60 || event_seq !== saved_seq + 16'd1)
            $fatal(1, "head turn did not rearm");

        $display("PASS: exam_fsm");
        $finish;
    end

endmodule
