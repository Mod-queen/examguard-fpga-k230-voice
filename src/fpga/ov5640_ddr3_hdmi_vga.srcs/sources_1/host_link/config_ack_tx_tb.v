`timescale 1ns/1ps

// Self-checking testbench for config_ack_tx. It decodes the transmitted
// 8-N-1 line and compares it against the expected "CA,<version>,<status>\n".
module config_ack_tx_tb;

    localparam integer CLK_FREQ_HZ  = 500000;
    localparam integer BAUD_RATE    = 50000;
    localparam integer CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE;
    localparam integer BIT_NS       = CLKS_PER_BIT * 10; // 10 ns clock period

    reg        clk = 1'b0;
    reg        rst = 1'b1;
    reg        trigger = 1'b0;
    reg  [7:0] version = 8'd5;
    reg  [2:0] status = 3'd0;
    wire       busy;
    wire       uart_txd;

    integer    errors = 0;
    reg [7:0]  expected [0:8];
    reg [7:0]  got [0:8];

    config_ack_tx #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .BAUD_RATE   (BAUD_RATE)
    ) dut (
        .clk      (clk),
        .rst      (rst),
        .trigger  (trigger),
        .version  (version),
        .status   (status),
        .busy     (busy),
        .uart_txd (uart_txd)
    );

    always #5 clk = ~clk;

    task recv_byte;
        output [7:0] value;
        integer i;
        begin
            @(negedge uart_txd);
            // Skip the start bit and land on the centre of data bit 0.
            #(BIT_NS + BIT_NS / 2);
            for (i = 0; i < 8; i = i + 1) begin
                value[i] = uart_txd;
                #(BIT_NS);
            end
        end
    endtask

    task wait_idle;
        integer guard;
        begin
            guard = 0;
            while (busy && guard < 100) begin
                @(posedge clk);
                guard = guard + 1;
            end
        end
    endtask

    task check_line;
        integer i;
        reg ok;
        begin
            for (i = 0; i < 9; i = i + 1)
                recv_byte(got[i]);
            ok = 1'b1;
            for (i = 0; i < 9; i = i + 1) begin
                if (got[i] !== expected[i]) begin
                    ok = 1'b0;
                    $display("  byte %0d: got 0x%02X expected 0x%02X",
                             i, got[i], expected[i]);
                end
            end
            if (ok)
                $display("  line OK: %c%c%c%c%c%c%c%c%c",
                         got[0], got[1], got[2], got[3], got[4],
                         got[5], got[6], got[7], got[8]);
            else begin
                errors = errors + 1;
                $display("  line MISMATCH");
            end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // Accepted acknowledgement: version 5, status 0.
        expected[0] = "C"; expected[1] = "A"; expected[2] = ",";
        expected[3] = "0"; expected[4] = "0"; expected[5] = "5";
        expected[6] = ","; expected[7] = "0"; expected[8] = 8'h0A;
        trigger = 1'b1; @(posedge clk); trigger = 1'b0;
        check_line;
        wait_idle;
        if (busy !== 1'b0) begin
            $display("FAIL: busy stuck high after first line");
            errors = errors + 1;
        end

        // Version 142 with a rejection status.
        version = 8'd142;
        status  = 3'd2;
        expected[3] = "1"; expected[4] = "4"; expected[5] = "2";
        expected[7] = "2";
        trigger = 1'b1; @(posedge clk); trigger = 1'b0;
        check_line;
        wait_idle;
        if (busy !== 1'b0) begin
            $display("FAIL: busy stuck high after second line");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("config_ack_tx_tb PASS");
        else
            $display("config_ack_tx_tb FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #(BIT_NS * 12 * 20);
        $display("config_ack_tx_tb TIMEOUT");
        $finish;
    end

endmodule
