`timescale 1ns/1ps

// Self-checking TB for the identity boundary. ID_WIDTH is small so boot_id and
// session_id saturation are exercised directly.
module event_identity_tb;
    localparam ID_WIDTH = 2;  // 0..3, saturates quickly

    reg clk = 0, rst = 1, ms_tick = 0, boot_pulse = 0, session_start = 0, session_end = 0;
    reg [ID_WIDTH-1:0] device_straps = 2'b10;
    wire [ID_WIDTH-1:0] device_id, boot_id, session_id;
    wire [63:0] time_ms;
    wire session_active, boot_event, session_event;
    wire [31:0] started_count, ignored_start_count;
    integer errors = 0;

    event_identity #(.ID_WIDTH(ID_WIDTH)) dut (
        .clk(clk), .rst(rst), .ms_tick(ms_tick), .device_straps(device_straps),
        .boot_pulse(boot_pulse), .session_start(session_start), .session_end(session_end),
        .device_id(device_id), .boot_id(boot_id), .session_id(session_id),
        .time_ms(time_ms), .session_active(session_active), .boot_event(boot_event),
        .session_event(session_event), .started_count(started_count),
        .ignored_start_count(ignored_start_count));

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
        check(time_ms == 0 && boot_id == 0 && session_id == 0 && !session_active && !session_event,
              "reset clears identity");
        rst = 0;
        @(posedge clk);
        check(boot_id == 1, "power-on boot is 1");
        check(boot_event == 1, "boot_event pulses on first boot");
        check(device_id == 2'b10, "device straps latched");
        @(posedge clk);
        check(boot_event == 0, "boot_event is one cycle");

        tick(5);
        check(time_ms == 5, "monotonic ms increments");
        tick(3);
        check(time_ms == 8, "monotonic ms continues");

        one_pulse(boot_pulse);
        @(posedge clk);
        check(boot_id == 2, "soft boot increments boot_id");

        one_pulse(session_start);
        check(session_active && session_id == 1, "first session starts");
        check(session_event == 1, "session_event pulses");
        check(started_count == 1, "started_count is 1");
        @(posedge clk);
        check(session_event == 0, "session_event is one cycle");

        one_pulse(session_start);
        check(session_active && session_id == 1, "duplicate start keeps session");
        check(ignored_start_count == 1, "duplicate start counted, not re-IDed");

        one_pulse(session_end);
        check(!session_active, "session_end clears active");
        one_pulse(session_start);
        check(session_active && session_id == 2, "next session gets new id");

        one_pulse(boot_pulse);
        @(posedge clk);
        check(boot_id == 3, "boot_id reaches max");
        one_pulse(boot_pulse);
        @(posedge clk);
        check(boot_id == 3, "boot_id saturates without wrap");

        one_pulse(session_end);
        one_pulse(session_start);
        check(session_id == 3, "session_id reaches max");
        one_pulse(session_end);
        one_pulse(session_start);
        check(session_id == 3 && session_active, "session_id saturates without wrap");

        rst = 1;
        repeat (2) @(posedge clk);
        check(boot_id == 0 && session_id == 0 && time_ms == 0 && !session_active,
              "reset returns identity to zero");

        if (errors == 0) $display("PASS: event_identity all checks");
        else $display("FAIL: event_identity %0d errors", errors);
        $finish;
    end
endmodule
