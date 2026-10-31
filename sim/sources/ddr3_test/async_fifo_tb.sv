`timescale 1ns/1ps

// Two-clock-domain TB for the async FIFO: randomized write/read over
// asynchronous clocks with a shared scoreboard, then a drain. Verifies order,
// data integrity and that a full FIFO drops nothing (writes just not accepted).
module async_fifo_tb;
    localparam integer DW = 16, DEPTH = 16;

    reg wclk = 0, rclk = 0;
    reg wrst_n = 0, rrst_n = 0;
    reg winc = 0, rinc = 0;
    reg [DW-1:0] wdata = 0;
    wire wfull, rempty;
    wire [DW-1:0] rdata;

    integer errors = 0;
    integer exp_wr = 0, exp_rd = 0;
    reg [DW-1:0] expected [0:100000];

    reg [31:0] prng_w = 32'h1234_5678;
    reg [31:0] prng_r = 32'h9E37_79B9;
    wire [31:0] pw_next = {prng_w[30:0], prng_w[31]^prng_w[21]};
    wire [31:0] pr_next = {prng_r[30:0], prng_r[31]^prng_r[21]};

    reg running = 0;
    // The exact enables the DUT sees: during drain, writes off / reads on.
    wire fifo_winc = running ? winc : 1'b0;
    wire fifo_rinc = running ? rinc : 1'b1;

    async_fifo #(.DATA_WIDTH(DW), .DEPTH(DEPTH)) dut (
        .wclk(wclk), .wrst_n(wrst_n), .winc(fifo_winc), .wdata(wdata), .wfull(wfull),
        .rclk(rclk), .rrst_n(rrst_n), .rinc(fifo_rinc), .rdata(rdata), .rempty(rempty));

    always #5 wclk = ~wclk;   // 100 MHz
    always #7 rclk = ~rclk;   // ~71 MHz

    task check(input cond, input [255:0] name);
        begin if (!cond) begin errors = errors + 1; $display("FAIL: %0s", name); end end
    endtask

    // Random enables (only while running).
    always @(posedge wclk) if (wrst_n && running) begin prng_w <= pw_next; winc <= pw_next[0]; end
    always @(posedge rclk) if (rrst_n && running) begin prng_r <= pr_next; rinc <= pr_next[0]; end

    // Scoreboard: log accepted writes, check accepted reads against the log.
    always @(posedge wclk) begin
        if (wrst_n && fifo_winc && !wfull) begin
            expected[exp_wr] = wdata;
            exp_wr = exp_wr + 1;
            wdata <= wdata + 16'd1;
        end
    end
    always @(posedge rclk) begin
        if (rrst_n && fifo_rinc && !rempty) begin
            if (rdata !== expected[exp_rd]) begin
                errors = errors + 1;
                $display("FAIL: order/data at %0d got %0d want %0d", exp_rd, rdata, expected[exp_rd]);
            end
            exp_rd = exp_rd + 1;
        end
    end

    integer i;
    initial begin
        repeat (4) @(posedge wclk);
        wrst_n = 1; rrst_n = 1;
        running = 1;
        repeat (4) @(posedge wclk);

        repeat (20000) @(posedge wclk);

        running = 0;   // stop the random generators; fifo_winc=0, fifo_rinc=1
        for (i = 0; i < 200000 && !rempty; i = i + 1) @(posedge rclk);
        repeat (20) @(posedge rclk);

        $display("written=%0d read=%0d", exp_wr, exp_rd);
        check(errors == 0, "no order/data errors");
        check(exp_wr == exp_rd, "all accepted writes were read back");
        check(exp_wr > 1000, "exercised a meaningful number of transfers");

        if (errors == 0) $display("PASS: async_fifo all checks");
        else $display("FAIL: async_fifo %0d errors", errors);
        $finish;
    end
endmodule
