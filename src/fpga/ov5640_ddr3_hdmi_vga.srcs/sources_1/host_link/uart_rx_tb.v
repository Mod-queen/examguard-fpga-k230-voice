`timescale 1ns/1ps

module uart_rx_tb;

    // 1 MHz clock and 100 kBd gives 10 clocks per bit for a short test.
    localparam integer CLKS_PER_BIT = 10;

    reg        clk;
    reg        rst;
    reg        rx;
    wire [7:0] data;
    wire       valid;

    uart_rx #(
        .CLK_FREQ_HZ (1000000),
        .BAUD_RATE   (100000)
    ) dut (
        .clk   (clk),
        .rst   (rst),
        .rx    (rx),
        .data  (data),
        .valid (valid)
    );

    always #5 clk = ~clk;

    integer i;
    integer errors;
    reg [7:0] received;

    // Transmit one byte by bit-banging the line.
    task send_byte;
        input [7:0] value;
        begin
            rx = 1'b0;
            #(CLKS_PER_BIT * 10);
            for (i = 0; i < 8; i = i + 1) begin
                rx = value[i];
                #(CLKS_PER_BIT * 10);
            end
            rx = 1'b1;
            #(CLKS_PER_BIT * 10);
        end
    endtask

    // Capture the first byte reported valid.
    always @(posedge clk) begin
        if (valid)
            received <= data;
    end

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        rx = 1'b1;
        errors = 0;
        received = 8'h00;

        repeat (4) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);

        // Idle line must not produce a byte.
        repeat (20) @(negedge clk);
        if (valid) begin
            $display("FAIL: idle line produced a byte");
            $finish;
        end

        // Receive a known byte.
        fork
            send_byte(8'h41);   // 'A'
            begin
                wait (valid == 1'b1);
                #1;
                if (data !== 8'h41) begin
                    $display("FAIL: expected 41 got %02x", data);
                    errors = errors + 1;
                end
            end
        join

        // Receive a byte with alternating bits.
        fork
            send_byte(8'hA5);
            begin
                wait (valid == 1'b1);
                #1;
                if (data !== 8'hA5) begin
                    $display("FAIL: expected A5 got %02x", data);
                    errors = errors + 1;
                end
            end
        join

        // A glitch shorter than half a bit must not start a frame.
        rx = 1'b0;
        #(CLKS_PER_BIT * 2);
        rx = 1'b1;
        repeat (40) @(negedge clk);
        if (valid) begin
            $display("FAIL: short glitch was decoded as a byte");
            errors = errors + 1;
        end

        if (errors != 0) begin
            $display("FAIL: uart_rx (%0d errors)", errors);
            $finish;
        end

        $display("PASS: uart receiver");
        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL: uart_rx timeout");
        $finish;
    end

endmodule
