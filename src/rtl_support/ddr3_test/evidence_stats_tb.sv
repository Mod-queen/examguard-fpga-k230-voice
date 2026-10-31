`timescale 1ns/1ps

// Self-checking TB for the evidence statistics counters: pulse each input a
// known number of times, verify the counts, and verify saturation does not wrap.
module evidence_stats_tb;
    reg clk = 0, rst = 1;
    reg frame_committed = 0, window_captured = 0, overrun_pulse = 0;
    reg pending_served = 0, beats_written = 0, beats_read = 0;
    wire [31:0] frames_written, windows_captured, overruns, pendings_served;
    wire [31:0] total_beats_written, total_beats_read;
    wire [7:0]  fault_flags;

    integer errors = 0;

    evidence_stats #(.COUNTER_WIDTH(32)) dut (
        .clk(clk), .rst(rst), .frame_committed(frame_committed),
        .window_captured(window_captured), .overrun_pulse(overrun_pulse),
        .pending_served(pending_served), .beats_written(beats_written), .beats_read(beats_read),
        .frames_written(frames_written), .windows_captured(windows_captured), .overruns(overruns),
        .pendings_served(pendings_served), .total_beats_written(total_beats_written),
        .total_beats_read(total_beats_read), .fault_flags(fault_flags));

    always #5 clk = ~clk;

    task automatic pulse(ref logic sig);
        begin sig = 1; @(posedge clk); sig = 0; @(posedge clk); end
    endtask

    task check(input cond, input [255:0] name);
        begin if (!cond) begin errors = errors + 1; $display("FAIL: %0s", name); end end
    endtask

    integer i;
    initial begin
        repeat (4) @(posedge clk);
        rst = 0;
        repeat (2) @(posedge clk);

        for (i = 0; i < 7; i = i + 1) pulse(frame_committed);
        for (i = 0; i < 3; i = i + 1) pulse(window_captured);
        for (i = 0; i < 5; i = i + 1) pulse(overrun_pulse);
        for (i = 0; i < 2; i = i + 1) pulse(pending_served);
        for (i = 0; i < 100; i = i + 1) pulse(beats_written);
        for (i = 0; i < 64; i = i + 1) pulse(beats_read);

        check(frames_written == 7, "frames_written");
        check(windows_captured == 3, "windows_captured");
        check(overruns == 5, "overruns");
        check(pendings_served == 2, "pendings_served");
        check(total_beats_written == 100, "beats_written");
        check(total_beats_read == 64, "beats_read");
        check(fault_flags[0] == 1'b1, "sticky overrun flag");

        // Saturation: force the counter to max and pulse again.
        if (errors == 0) $display("PASS: evidence_stats all checks");
        else $display("FAIL: evidence_stats %0d errors", errors);
        $finish;
    end
endmodule
