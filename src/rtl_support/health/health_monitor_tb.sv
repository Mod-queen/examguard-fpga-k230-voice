`timescale 1ns/1ps

// Self-checking TB for the health monitor: camera freeze, K230 silence,
// evidence busy and sticky overrun are distinct and recoverable where expected.
module health_monitor_tb;
    localparam CAMERA_FROZEN_S = 3;
    localparam K230_SILENT_S   = 5;

    reg clk = 0, rst = 1, tick_1s = 0;
    reg camera_frame_pulse = 0, k230_pulse = 0, evidence_busy = 0, overrun_pulse = 0;
    wire [7:0]  health_flags;
    wire [15:0] overrun_count, camera_silent_s, k230_silent_s;

    integer errors = 0;

    health_monitor #(.CAMERA_FROZEN_S(CAMERA_FROZEN_S), .K230_SILENT_S(K230_SILENT_S)) dut (
        .clk(clk), .rst(rst), .tick_1s(tick_1s),
        .camera_frame_pulse(camera_frame_pulse), .k230_pulse(k230_pulse),
        .evidence_busy(evidence_busy), .overrun_pulse(overrun_pulse),
        .health_flags(health_flags), .overrun_count(overrun_count),
        .camera_silent_s(camera_silent_s), .k230_silent_s(k230_silent_s));

    always #5 clk = ~clk;

    task check(input cond, input [255:0] name);
        begin
            if (!cond) begin errors = errors + 1; $display("FAIL: %0s", name); end
        end
    endtask

    task automatic pulse1(ref logic sig);
        begin sig = 1; @(posedge clk); sig = 0; end
    endtask

    task tick_now();
        begin
            tick_1s = 1; @(posedge clk); tick_1s = 0;
            repeat (2) @(posedge clk);
        end
    endtask

    // One healthy second: both sources produce a frame, then the second ticks.
    task healthy_tick();
        begin
            camera_frame_pulse = 1; k230_pulse = 1; @(posedge clk);
            camera_frame_pulse = 0; k230_pulse = 0;
            tick_now();
        end
    endtask

    // One second with only the named source reporting.
    task camera_only_tick();
        begin
            camera_frame_pulse = 1; @(posedge clk); camera_frame_pulse = 0;
            tick_now();
        end
    endtask

    task k230_only_tick();
        begin
            k230_pulse = 1; @(posedge clk); k230_pulse = 0;
            tick_now();
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst = 0;
        repeat (2) @(posedge clk);
        check(health_flags == 8'h00, "healthy start has no flags");

        healthy_tick();
        healthy_tick();
        check(health_flags == 8'h00, "healthy ticks keep flags clear");

        // Camera stops, K230 keeps reporting: only camera flag rises.
        k230_only_tick();
        k230_only_tick();
        k230_only_tick();
        check(camera_silent_s == CAMERA_FROZEN_S, "camera silent seconds counted");
        check(health_flags[0] == 1'b1, "camera frozen flag set");
        check(health_flags[1] == 1'b0, "k230 not flagged while it reports");

        // Camera recovers: flag clears.
        healthy_tick();
        check(camera_silent_s == 0, "camera silence resets");
        check(health_flags[0] == 1'b0, "camera frozen flag clears on recovery");

        // K230 stops, camera keeps reporting: only k230 flag rises.
        camera_only_tick();
        camera_only_tick();
        camera_only_tick();
        camera_only_tick();
        camera_only_tick();
        check(k230_silent_s == K230_SILENT_S, "k230 silent seconds counted");
        check(health_flags[1] == 1'b1, "k230 silent flag set");
        check(health_flags[0] == 1'b0, "camera not flagged while it reports");

        // Evidence busy is a live level.
        evidence_busy = 1; @(posedge clk); @(posedge clk);
        check(health_flags[2] == 1'b1, "evidence busy reflected");
        evidence_busy = 0; @(posedge clk); @(posedge clk);
        check(health_flags[2] == 1'b0, "evidence busy clears");

        // Overrun is counted and sticky.
        pulse1(overrun_pulse); @(posedge clk);
        pulse1(overrun_pulse); @(posedge clk);
        check(overrun_count == 16'd2, "overrun counted");
        check(health_flags[3] == 1'b1, "overrun seen sticky");
        healthy_tick();
        check(health_flags[3] == 1'b1, "overrun flag stays until reset");

        if (errors == 0) $display("PASS: health_monitor all checks");
        else $display("FAIL: health_monitor %0d errors", errors);
        $finish;
    end
endmodule
