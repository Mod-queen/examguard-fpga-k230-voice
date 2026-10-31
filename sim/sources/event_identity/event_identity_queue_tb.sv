`timescale 1ns/1ps

// Independent integration TB: event_identity feeds event_transaction_queue.
// Proves accepted events carry the live device/boot/session/time fields and a
// fresh event ID, and that the event ID is distinct from the session ID.
module event_identity_queue_tb;
    localparam ID_WIDTH = 4;
    localparam DEPTH = 4;

    reg clk = 0, rst = 1, ms_tick = 0;
    reg [ID_WIDTH-1:0] device_straps = 4'h5;
    reg boot_pulse = 0, session_start = 0, session_end = 0;
    wire [ID_WIDTH-1:0] device_id, boot_id, session_id;
    wire [63:0] time_ms;
    wire session_active, boot_event, session_event;
    wire [31:0] started_count, ignored_start_count;

    reg [3:0] request = 0;
    reg [63:0] request_data = 0;
    reg event_ready = 0;
    wire [3:0] accepted, rejected;
    wire event_valid;
    wire [255:0] event_data;
    wire [2:0] occupancy, high_water;
    wire [31:0] accepted_count, rejected_count, delivered_count;
    wire id_exhausted;

    integer errors = 0;

    event_identity #(.ID_WIDTH(ID_WIDTH)) ident (
        .clk(clk), .rst(rst), .ms_tick(ms_tick), .device_straps(device_straps),
        .boot_pulse(boot_pulse), .session_start(session_start), .session_end(session_end),
        .device_id(device_id), .boot_id(boot_id), .session_id(session_id), .time_ms(time_ms),
        .session_active(session_active), .boot_event(boot_event), .session_event(session_event),
        .started_count(started_count), .ignored_start_count(ignored_start_count));

    event_transaction_queue #(.DEPTH(DEPTH), .ID_WIDTH(64)) queue (
        .clk(clk), .rst(rst), .request(request), .request_data(request_data),
        .device_id(device_id), .boot_id(boot_id), .session_id(session_id),
        .request_time_ms(time_ms), .accepted(accepted), .rejected(rejected),
        .event_valid(event_valid), .event_ready(event_ready), .event_data(event_data),
        .occupancy(occupancy), .high_water(high_water), .accepted_count(accepted_count),
        .rejected_count(rejected_count), .delivered_count(delivered_count), .id_exhausted(id_exhausted));

    always #5 clk = ~clk;

    task check(input cond, input [255:0] name);
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("FAIL: %0s", name);
            end
        end
    endtask

    task tick(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                ms_tick = 1; @(posedge clk); ms_tick = 0; @(posedge clk);
            end
        end
    endtask

    task automatic one_pulse(ref logic signal);
        begin
            signal = 1; @(posedge clk); signal = 0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);
        @(posedge clk);
        check(boot_id == 4'h1, "identity boot id is 1");

        tick(7);
        one_pulse(session_start);
        check(session_id == 4'h1 && session_active, "identity session id is 1");
        // Advance to session 2 so the event ID (1) is provably not the session ID.
        one_pulse(session_end);
        one_pulse(session_start);
        check(session_id == 4'h2 && session_active, "identity session id is 2");

        // Issue one object-source request (source 1) while holding the event.
        request = 4'b0010; request_data[16 +: 16] = 16'h50A5;
        @(posedge clk);
        request = 0; request_data = 0;
        @(posedge clk);
        @(posedge clk);
        check(event_valid, "event queued");
        check(accepted_count == 1, "one accepted");
        check(event_data[255:224] == {28'b0, device_id}, "event device id matches identity");
        check(event_data[223:192] == {28'b0, boot_id}, "event boot id matches identity");
        check(event_data[191:160] == {28'b0, session_id}, "event session id matches identity");
        check(event_data[159:96] == 64'd1, "first event id is 1");
        check(event_data[159:96] != {60'b0, session_id}, "event id distinct from session id");
        check(event_data[95:32] == time_ms, "event time matches identity clock");
        check(event_data[31:24] == 8'd1, "event source is 1");
        check(event_data[15:0] == 16'h50A5, "event lane payload preserved");

        // Event ID advances independently of the session ID.
        event_ready = 1; @(posedge clk); event_ready = 0;
        @(posedge clk);
        request = 4'b0001; request_data[0 +: 16] = 16'h0064;
        @(posedge clk);
        request = 0; request_data = 0;
        @(posedge clk);
        @(posedge clk);
        check(event_valid, "second event queued");
        check(event_data[159:96] == 64'd2, "second event id is 2");
        check(event_data[191:160] == {28'b0, session_id}, "second event keeps session id");
        check(event_data[31:24] == 8'd0, "second event source is 0");
        check(event_data[15:0] == 16'h0064, "second lane payload preserved");

        if (errors == 0) $display("PASS: event_identity_queue all checks");
        else $display("FAIL: event_identity_queue %0d errors", errors);
        $finish;
    end
endmodule
