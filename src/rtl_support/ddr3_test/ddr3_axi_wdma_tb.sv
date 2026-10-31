`timescale 1ns/1ps

// Self-checking TB for the write DMA: an input stream of numbered beats is
// written through a behavioral AXI write slave with random wait states; every
// accepted beat must land in order with no loss.
module ddr3_axi_wdma_tb;
    localparam integer DW = 128, AW = 30, IW = 4, BURST = 16;
    localparam integer BURSTS = 8, TOTAL = BURSTS*BURST;

    reg clk = 0, rst = 1, start = 0;
    reg [AW-1:0] base = 0;
    reg [15:0]   count = BURSTS;

    wire [IW-1:0] awid, bid;
    wire [AW-1:0] awaddr;
    wire [7:0]    awlen;
    wire [2:0]    awsize;
    wire [1:0]    awburst, bresp;
    wire          awvalid, awready, wvalid, wready, wlast, bvalid, bready;
    wire [DW-1:0] wdata;
    wire [DW/8-1:0] wstrb;
    wire [31:0] beats_written, cycles, error_count;
    wire busy, done;

    reg  in_valid = 1, in_last;
    wire in_ready;
    reg [31:0] seq = 0;
    wire [DW-1:0] in_data = seq;
    wire in_last_w = (seq == TOTAL-1);

    integer errors = 0;
    reg done_seen = 0;
    always @(posedge clk) if (done) done_seen <= 1'b1;

    ddr3_axi_wdma #(.DATA_WIDTH(DW), .ADDR_WIDTH(AW), .ID_WIDTH(IW), .BURST(BURST)) dut (
        .clk(clk), .rst(rst), .start(start), .base_addr(base), .burst_count(count),
        .in_valid(in_valid), .in_data(in_data), .in_last(in_last_w), .in_ready(in_ready),
        .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
        .m_axi_awburst(awburst), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast), .m_axi_wvalid(wvalid),
        .m_axi_wready(wready),
        .m_axi_bid(bid), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
        .busy(busy), .done(done), .beats_written(beats_written), .cycles(cycles),
        .error_count(error_count));

    always #5 clk = ~clk;

    // Behavioral AXI write slave with random wait states.
    reg [AW-1:0] wbase; reg [7:0] wlen; reg [7:0] wbeat; reg w_active;
    reg [DW-1:0] mem [0:65535];
    reg [31:0] wseq = 0;
    reg [31:0] prng = 32'hACE1_2345;
    wire [31:0] prng_next = {prng[30:0], prng[31]^prng[21]};
    reg aw_ready_r = 0, w_ready_r = 0, bvalid_r = 0;
    assign awready = aw_ready_r;
    assign wready  = w_ready_r;
    assign bvalid  = bvalid_r;
    assign bid     = 4'd0; assign bresp = 2'd0;

    always @(posedge clk) begin
        if (rst) begin
            aw_ready_r <= 0; w_ready_r <= 0; bvalid_r <= 0; w_active <= 0;
            wbeat <= 0; wseq <= 0; prng <= 32'hACE1_2345;
        end else begin
            prng <= prng_next;
            aw_ready_r <= !w_active ? ~prng[0] : 1'b0;
            if (awvalid && awready) begin
                wbase <= awaddr; wlen <= awlen; wbeat <= 0; w_active <= 1'b1;
            end
            w_ready_r <= w_active ? ~prng[7] : 1'b0;
            if (w_active && wvalid && wready) begin
                mem[wseq] <= wdata;
                wseq <= wseq + 1;
                if (wbeat == wlen) begin w_active <= 0; bvalid_r <= 1; end
                else wbeat <= wbeat + 1;
            end
            if (bvalid_r && bready) bvalid_r <= 0;
        end
    end

    // Input stream.
    always @(posedge clk) begin
        if (rst) begin seq <= 0; in_valid <= 1; end
        else if (in_valid && in_ready) begin
            seq <= seq + 1;
            if (seq + 1 >= TOTAL) in_valid <= 0;
        end
    end

    task check(input cond, input [255:0] name);
        begin if (!cond) begin errors = errors + 1; $display("FAIL: %0s", name); end end
    endtask

    integer i;
    initial begin
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk);

        start = 1; @(posedge clk); start = 0;
        for (i = 0; i < 100000 && !done_seen; i = i + 1) @(posedge clk);
        repeat (5) @(posedge clk);

        $display("beats_written=%0d cycles=%0d errors=%0d", beats_written, cycles, error_count);
        check(done_seen, "write DMA completes");
        check(beats_written == TOTAL, "all beats written");
        check(error_count == 0, "no write errors");
        for (i = 0; i < TOTAL; i = i + 1)
            if (mem[i] !== i) begin
                errors = errors + 1;
                $display("FAIL: mem[%0d]=%0d want %0d", i, mem[i], i);
                if (errors > 4) i = TOTAL;
            end

        if (errors == 0) $display("PASS: ddr3_axi_wdma all checks");
        else $display("FAIL: ddr3_axi_wdma %0d errors", errors);
        $finish;
    end
endmodule
