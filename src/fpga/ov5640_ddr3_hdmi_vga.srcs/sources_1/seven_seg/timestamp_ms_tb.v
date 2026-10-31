`timescale 1ns/1ps

module timestamp_ms_tb;

    reg clk;
    reg rst;
    wire [31:0] timestamp_ms;

    // 10 kHz clock and 1 kHz tick gives a divider of 10 for a short test.
    timestamp_ms #(
        .CLK_HZ (10000)
    ) dut (
        .clk          (clk),
        .rst          (rst),
        .timestamp_ms (timestamp_ms)
    );

    always #5 clk = ~clk;

    integer i;
    integer ticks;

    initial begin
        clk = 1'b0;
        rst = 1'b1;

        repeat (4) @(negedge clk);
        rst = 1'b0;

        if (timestamp_ms !== 32'd0) begin
            $display("FAIL: counter not cleared on reset");
            $finish;
        end

        // One millisecond equals CLK_HZ/1000 = 10 clocks, so the counter
        // advances on the tenth rising edge (clock index 9).
        ticks = 0;
        for (i = 0; i < 100; i = i + 1) begin
            @(posedge clk);
            #1;
            if (timestamp_ms !== (i + 1) / 10) begin
                $display("FAIL: at clock %0d expected %0d got %0d",
                         i, (i + 1) / 10, timestamp_ms);
                $finish;
            end
        end

        $display("PASS: millisecond timestamp");
        $finish;
    end

endmodule
