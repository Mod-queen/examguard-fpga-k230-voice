`timescale 1ns/1ps

// Reference model checks admission, immutable payload, contiguous accepted IDs,
// full+pop, backpressure, reset flush, and explicit ID-space exhaustion.
module transaction_queue_checker #(
    parameter DEPTH = 3,
    parameter ID_WIDTH = 64
)(output reg done = 0);
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg [3:0] request = 0;
    reg [63:0] lanes = 0;
    reg [31:0] device = 32'hac750001, boot = 17, session = 0;
    reg [63:0] stamp = 0;
    reg ready = 0;
    wire [3:0] accepted, rejected;
    wire valid, exhausted;
    wire [255:0] data;
    wire [$clog2(DEPTH+1)-1:0] occupancy, high_water;
    wire [31:0] naccept, nreject, ndeliver;
    event_transaction_queue #(.DEPTH(DEPTH), .ID_WIDTH(ID_WIDTH)) dut (
        .clk(clk), .rst(rst), .request(request), .request_data(lanes),
        .device_id(device), .boot_id(boot), .session_id(session), .request_time_ms(stamp),
        .accepted(accepted), .rejected(rejected), .event_valid(valid), .event_ready(ready),
        .event_data(data), .occupancy(occupancy), .high_water(high_water),
        .accepted_count(naccept), .rejected_count(nreject), .delivered_count(ndeliver),
        .id_exhausted(exhausted)
    );
    localparam [63:0] MAX_ID = {64{1'b1}} >> (64-ID_WIDTH);
    reg [255:0] model [0:DEPTH-1];
    reg [63:0] last_id = 0;
    reg [3:0] expect_accept, expect_reject;
    integer count = 0, peak = 0, accepts = 0, rejects = 0, delivers = 0;
    integer slots, source, k, cycle, seed;
    integer saw_full_pop = 0, saw_reject = 0, saw_stall = 0;

    task step;
        begin
            #1;
            if (valid !== (count != 0 && !rst)) $fatal(1, "valid mismatch depth=%0d", DEPTH);
            if (count && !rst && data !== model[0]) $fatal(1, "head payload changed depth=%0d", DEPTH);
            expect_accept = 0; expect_reject = 0;
            if (rst) begin
                count = 0; peak = 0; accepts = 0; rejects = 0; delivers = 0; last_id = 0;
            end else begin
                if (count == DEPTH && ready) saw_full_pop = saw_full_pop + 1;
                if (count && !ready) saw_stall = saw_stall + 1;
                if (count && ready) begin
                    for (k = 0; k < count-1; k = k+1) model[k] = model[k+1];
                    count = count-1; delivers = delivers+1;
                end
                slots = DEPTH-count;
                for (source = 0; source < 4; source = source+1) begin
                    if (request[source]) begin
                        if (slots && last_id < MAX_ID) begin
                            expect_accept[source] = 1;
                            last_id = last_id+1;
                            model[count] = {device, boot, session, last_id, stamp,
                                source[7:0], 8'd0, lanes[source*16 +: 16]};
                            slots = slots-1; count = count+1; accepts = accepts+1;
                        end else begin
                            expect_reject[source] = 1;
                            rejects = rejects+1; saw_reject = saw_reject+1;
                        end
                    end
                end
                if (count > peak) peak = count;
            end
            if (accepted !== expect_accept || rejected !== expect_reject)
                $fatal(1, "admission mismatch depth=%0d got=%b/%b expected=%b/%b", DEPTH,
                    accepted, rejected, expect_accept, expect_reject);
            @(posedge clk); #1;
            if (occupancy !== count || high_water !== peak || naccept !== accepts ||
                nreject !== rejects || ndeliver !== delivers || exhausted !== (last_id == MAX_ID))
                $fatal(1, "accounting mismatch depth=%0d cycle=%0d", DEPTH, cycle);
            @(negedge clk);
        end
    endtask

    initial begin
        seed = 6102 + DEPTH;
        @(negedge clk); step;
        rst = 0;
        // Force full, reject, hold, and simultaneous full+pop before random work.
        request = 15; lanes = 64'h3333222211110000;
        repeat (DEPTH+2) step;
        ready = 1; repeat (4) step;
        for (cycle = 0; cycle < 1500; cycle = cycle+1) begin
            request = $random(seed);
            ready = ($random(seed) & 3) != 0;
            lanes = {$random(seed), $random(seed)};
            stamp = {$random(seed), $random(seed)}; // backward/uint64 timestamps are opaque
            session = cycle / 11; device = device+1;
            // Reset flushes queued events and ID space; caller supplies NEW boot.
            rst = (cycle == 700);
            if (rst) boot = boot+1;
            step;
        end
        request = 0; ready = 1; repeat (DEPTH+1) step;
        if (!saw_full_pop || !saw_reject || !saw_stall) $fatal(1, "coverage gap");
        if (ID_WIDTH < 64 && !exhausted) $fatal(1, "ID exhaustion not reached");
        $display("PASS: transaction reference depth=%0d ID_WIDTH=%0d random=1500", DEPTH, ID_WIDTH);
        done = 1;
    end
endmodule

module fsm_transaction_checker(output reg done = 0);
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1, tick = 0, frame = 0, face = 0, start = 0, submit = 0, ack = 0;
    reg object_pulse = 0, gaze = 0, away = 0, present = 0, timeout = 0;
    reg [2:0] object_class = 0;
    reg [7:0] activity = 10, luma = 120;
    reg [15:0] cells = 0;
    wire [3:0] request;
    wire [63:0] lanes;
    wire [2:0] stage;
    wire [1:0] risk;
    wire [7:0] code;
    wire [15:0] seqno;
    exam_fsm #(.SELFCHECK_TICKS(1), .GAZE_TURN_FRAMES(1),
        .LOW_ACT_FRAMES(1), .PARALLEL_EVENTS(1)) fsm (
        .clk(clk), .rst(rst), .tick_1s(tick), .frame_pulse(frame),
        .face_pulse(face), .face_ok(1'b1), .face_id(2'd1),
        .object_pulse(object_pulse), .object_class(object_class),
        .activity_global(activity), .active_cells(cells), .luma_avg(luma),
        .gaze_pulse(gaze), .gaze_away(away), .gaze_present(present),
        .start_pulse(start), .submit_pulse(submit), .ack_pulse(ack),
        .timeout_pulse(timeout), .stage_id(stage), .risk_level(risk),
        .event_code(code), .event_seq(seqno), .remaining_s(), .authorized_id(),
        .new_event(), .debug_luma(), .debug_base(), .debug_flags(), .debug_gaze_cnt(),
        .event_request(request), .event_request_data(lanes)
    );
    // Match metadata pipeline to the FSM's registered request output.
    reg [63:0] now_ms = 0, request_ms = 0;
    reg [31:0] boot = 1, session = 0, request_session = 0;
    always @(posedge clk) begin
        if (rst) begin now_ms <= 0; request_ms <= 0; request_session <= 0; end
        else begin now_ms <= now_ms+1; request_ms <= now_ms; request_session <= session; end
    end
    reg ready = 0;
    wire valid;
    wire [255:0] data;
    wire [3:0] accepted, rejected;
    wire [3:0] occupancy, high_water;
    wire [31:0] naccept, nreject, ndeliver;
    event_transaction_queue #(.DEPTH(8)) queue (
        .clk(clk), .rst(rst), .request(request), .request_data(lanes),
        .device_id(32'hac750001), .boot_id(boot), .session_id(request_session),
        .request_time_ms(request_ms), .accepted(accepted), .rejected(rejected),
        .event_valid(valid), .event_ready(ready), .event_data(data),
        .occupancy(occupancy), .high_water(high_water), .accepted_count(naccept),
        .rejected_count(nreject), .delivered_count(ndeliver), .id_exhausted()
    );
    reg [63:0] collision_ms;
    task consume;
        input [7:0] expect_code;
        input [7:0] expect_source;
        input [63:0] expect_id;
        input [2:0] expect_stage;
        input [31:0] expect_session;
        input [63:0] expect_ms;
        begin
            if (!valid || data[7:0] !== expect_code || data[31:24] !== expect_source ||
                data[159:96] !== expect_id || data[191:160] !== expect_session ||
                data[14:12] !== expect_stage || data[11:10] !== 2'd1 ||
                data[223:192] !== boot || data[255:224] !== 32'hac750001 ||
                data[95:32] !== expect_ms || data[23:16] !== 0 || data[15] !== 0)
                $fatal(1, "FSM transaction mismatch code=%h source=%0d id=%0d data=%h",
                    expect_code, expect_source, expect_id, data);
            ready = 1; @(negedge clk); ready = 0;
        end
    endtask

    initial begin
        repeat (2) @(negedge clk); rst = 0;
        tick = 1; @(negedge clk); tick = 0;
        collision_ms = now_ms;
        face = 1; @(negedge clk); face = 0;
        if (request !== 1 || lanes[15:0] !== 16'h2401) $fatal(1, "auth request fields");
        @(negedge clk);
        consume(8'h01, 0, 1, 2, 0, collision_ms);
        session = 1; start = 1; @(negedge clk); start = 0;
        // All four sources in one clock: submit, phone, head turn and cover.
        collision_ms = now_ms;
        submit = 1; object_pulse = 1; object_class = 1;
        gaze = 1; away = 1; present = 1; frame = 1; cells = 2000;
        @(negedge clk);
        if (request !== 15 || code !== 8'h21 || seqno !== 2 || stage !== 4)
            $fatal(1, "four-way collision lost or panel arbitration incorrect");
        submit = 0; object_pulse = 0; gaze = 0; frame = 0;
        @(negedge clk);
        if (naccept !== 5 || nreject !== 0 || occupancy !== 4) $fatal(1, "four-way queue accounting");
        // Change live metadata while blocked; stored events must stay in session 1.
        session = 99;
        repeat (5) @(negedge clk);
        consume(8'h21, 0, 2, 4, 1, collision_ms);
        consume(8'h50, 1, 3, 3, 1, collision_ms);
        consume(8'h60, 2, 4, 3, 1, collision_ms);
        consume(8'h64, 3, 5, 3, 1, collision_ms);
        collision_ms = now_ms;
        ack = 1; @(negedge clk); ack = 0; @(negedge clk);
        consume(8'h03, 0, 6, 5, 99, collision_ms);
        if (naccept !== 6 || ndeliver !== 6 || high_water !== 4) $fatal(1, "drain accounting");

        // New boot: static darkness may hold display, but must not hide phone.
        rst = 1; boot = 2; session = 0;
        @(negedge clk); rst = 0; tick = 1;
        @(negedge clk); tick = 0; face = 1;
        @(negedge clk); face = 0;
        session = 2; start = 1; ready = 1;
        @(negedge clk); start = 0; frame = 1; cells = 0; luma = 120;
        @(negedge clk); frame = 0;
        @(negedge clk); frame = 1; luma = 20;
        @(negedge clk); frame = 0;
        @(negedge clk); // drain camera request
        frame = 1; object_pulse = 1; object_class = 1;
        @(negedge clk); frame = 0; object_pulse = 0;
        if (request !== 4'b0010 || code !== 8'h50 || risk !== 3)
            $fatal(1, "dark hold overwrote new severe object");
        repeat (3) @(negedge clk);
        // Stillness + gaze + notes independently survive the same frame.
        gaze = 1; away = 1; present = 1; object_pulse = 1; object_class = 2;
        frame = 1; activity = 0; luma = 120;
        @(negedge clk); gaze = 0; object_pulse = 0; frame = 0;
        if (request !== 4'b1110 || code !== 8'h51) $fatal(1, "three-way stillness collision");
        repeat (3) @(negedge clk);
        // Force timeout alongside a distinct video spike.
        frame = 1; cells = 2000; timeout = 1;
        @(negedge clk); frame = 0; timeout = 0;
        if (request !== 4'b1001 || code !== 8'h31 || stage !== 4)
            $fatal(1, "forced timeout collision");
        repeat (3) @(negedge clk);
        if (nreject !== 0 || naccept !== 8 || ndeliver !== 8)
            $fatal(1, "second boot event accounting accepts=%0d delivers=%0d", naccept, ndeliver);
        $display("PASS: FSM parallel transactions/auth/submission/timeout/dark hold/reset");
        done = 1;
    end
endmodule

module event_transaction_queue_tb;
    wire d1, d3, d16, dlimit, dfsm;
    transaction_queue_checker #(.DEPTH(1), .ID_WIDTH(4)) q1(d1);
    transaction_queue_checker #(.DEPTH(3)) q3(d3);
    transaction_queue_checker #(.DEPTH(16)) q16(d16);
    transaction_queue_checker #(.DEPTH(3), .ID_WIDTH(4)) qlimit(dlimit);
    fsm_transaction_checker fsm(dfsm);
    initial begin
        wait (d1 && d3 && d16 && dlimit && dfsm);
        $display("PASS: event_transaction_queue all configurations");
        $finish;
    end
    initial begin #1000000; $fatal(1, "test watchdog"); end
endmodule
