`timescale 1ns/1ps

module key_debounce_tb;

    reg clk;
    reg rst;
    reg key_n;
    wire pressed;
    wire press_pulse;

    // A tiny debounce window keeps the simulation short.
    key_debounce #(
        .CLK_FREQ_HZ (1000),
        .DEBOUNCE_MS (2)
    ) dut (
        .clk         (clk),
        .rst         (rst),
        .key_n       (key_n),
        .pressed     (pressed),
        .press_pulse (press_pulse)
    );

    always #5 clk = ~clk;

    task press_key;
        begin
            key_n = 1'b0;
            #1;
            key_n = 1'b1;
            #1;
            key_n = 1'b0;
            #60;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        key_n = 1'b1;

        repeat (4) @(negedge clk);
        rst = 1'b0;

        if (pressed !== 1'b0) begin
            $display("FAIL: idle key reported pressed");
            $finish;
        end

        // Bounce on press; it must settle to pressed with one pulse.
        press_key();
        if (pressed !== 1'b1) begin
            $display("FAIL: bounced press was not debounced");
            $finish;
        end

        // Release with bounce must return to idle.
        key_n = 1'b1;
        #5;
        key_n = 1'b0;
        #5;
        key_n = 1'b1;
        #60;
        if (pressed !== 1'b0) begin
            $display("FAIL: released key stayed pressed");
            $finish;
        end

        $display("PASS: key debounce");
        $finish;
    end

endmodule
