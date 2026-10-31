`timescale 1ns/1ps

// Compares a 1-outstanding read DMA against an 8-outstanding one on the same
// latency-modelled slave: the 8-outstanding run must finish in fewer cycles,
// and all streamed data must match the address-derived pattern.
module ddr3_axi_rdma_tb;
    localparam integer AW = 30, DW = 128, IW = 4, BURST = 16;
    localparam integer BURSTS = 32, LAT = 30;

    reg clk = 0, rst = 1;
    reg start = 0;
    reg [AW-1:0] base = 0;
    reg [15:0]   count = BURSTS;

    integer errors = 0;

    // ---- DUT with OUTSTANDING = 1 ----
    wire [IW-1:0] a1_id; wire [AW-1:0] a1_addr; wire [7:0] a1_len;
    wire [2:0] a1_size; wire [1:0] a1_burst; wire a1_valid; wire a1_ready;
    wire [IW-1:0] r1_id; wire [DW-1:0] r1_data; wire [1:0] r1_resp; wire r1_last, r1_valid;
    wire r1_ready;
    wire o1_valid, o1_last; wire [DW-1:0] o1_data;
    wire b1, d1; wire [31:0] br1, cy1;
    ddr3_axi_rdma #(.DATA_WIDTH(DW), .ADDR_WIDTH(AW), .ID_WIDTH(IW), .BURST(BURST), .OUTSTANDING(1)) u1 (
        .clk(clk), .rst(rst), .start(start), .base_addr(base), .burst_count(count),
        .m_axi_arid(a1_id), .m_axi_araddr(a1_addr), .m_axi_arlen(a1_len), .m_axi_arsize(a1_size),
        .m_axi_arburst(a1_burst), .m_axi_arvalid(a1_valid), .m_axi_arready(a1_ready),
        .m_axi_rid(r1_id), .m_axi_rdata(r1_data), .m_axi_rresp(r1_resp), .m_axi_rlast(r1_last),
        .m_axi_rvalid(r1_valid), .m_axi_rready(r1_ready),
        .out_valid(o1_valid), .out_data(o1_data), .out_last(o1_last), .out_ready(1'b1),
        .busy(b1), .done(d1), .beats_read(br1), .cycles(cy1));
    axi_rd_slave_model #(.ADDR_WIDTH(AW), .DATA_WIDTH(DW), .ID_WIDTH(IW), .BURST(BURST), .LATENCY(LAT)) s1 (
        .clk(clk), .rst(rst), .arid(a1_id), .araddr(a1_addr), .arlen(a1_len), .arsize(a1_size),
        .arburst(a1_burst), .arvalid(a1_valid), .arready(a1_ready),
        .rid(r1_id), .rdata(r1_data), .rresp(r1_resp), .rlast(r1_last), .rvalid(r1_valid), .rready(r1_ready));

    // ---- DUT with OUTSTANDING = 8 ----
    wire [IW-1:0] a8_id; wire [AW-1:0] a8_addr; wire [7:0] a8_len;
    wire [2:0] a8_size; wire [1:0] a8_burst; wire a8_valid; wire a8_ready;
    wire [IW-1:0] r8_id; wire [DW-1:0] r8_data; wire [1:0] r8_resp; wire r8_last, r8_valid;
    wire r8_ready;
    wire o8_valid, o8_last; wire [DW-1:0] o8_data;
    wire b8, d8; wire [31:0] br8, cy8;
    ddr3_axi_rdma #(.DATA_WIDTH(DW), .ADDR_WIDTH(AW), .ID_WIDTH(IW), .BURST(BURST), .OUTSTANDING(8)) u8 (
        .clk(clk), .rst(rst), .start(start), .base_addr(base), .burst_count(count),
        .m_axi_arid(a8_id), .m_axi_araddr(a8_addr), .m_axi_arlen(a8_len), .m_axi_arsize(a8_size),
        .m_axi_arburst(a8_burst), .m_axi_arvalid(a8_valid), .m_axi_arready(a8_ready),
        .m_axi_rid(r8_id), .m_axi_rdata(r8_data), .m_axi_rresp(r8_resp), .m_axi_rlast(r8_last),
        .m_axi_rvalid(r8_valid), .m_axi_rready(r8_ready),
        .out_valid(o8_valid), .out_data(o8_data), .out_last(o8_last), .out_ready(1'b1),
        .busy(b8), .done(d8), .beats_read(br8), .cycles(cy8));
    axi_rd_slave_model #(.ADDR_WIDTH(AW), .DATA_WIDTH(DW), .ID_WIDTH(IW), .BURST(BURST), .LATENCY(LAT)) s8 (
        .clk(clk), .rst(rst), .arid(a8_id), .araddr(a8_addr), .arlen(a8_len), .arsize(a8_size),
        .arburst(a8_burst), .arvalid(a8_valid), .arready(a8_ready),
        .rid(r8_id), .rdata(r8_data), .rresp(r8_resp), .rlast(r8_last), .rvalid(r8_valid), .rready(r8_ready));

    always #5 clk = ~clk;

    function [DW-1:0] data_of;
        input [29:0] a; input [4:0] b;
        begin data_of = {94'b0, a, b[3:0]}; end
    endfunction

    // done is a one-cycle pulse; latch each engine's completion.
    reg done1_seen = 0, done8_seen = 0;
    always @(posedge clk) begin
        if (d1) done1_seen <= 1'b1;
        if (d8) done8_seen <= 1'b1;
    end

    // Check the 8-outstanding streamed data against the address-derived pattern.
    integer chk_beat = 0;
    integer mismatches = 0;
    always @(posedge clk) begin
        if (!rst && o8_valid && 1'b1) begin // out_ready tied 1
            if (o8_data !== data_of(base + (chk_beat / BURST) * (BURST*16), chk_beat % BURST))
                mismatches <= mismatches + 1;
            chk_beat <= chk_beat + 1;
        end
    end

    task check(input cond, input [255:0] name);
        begin if (!cond) begin errors = errors + 1; $display("FAIL: %0s", name); end end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk);

        start = 1; @(posedge clk); start = 0;

        begin : wait_done
            integer w;
            for (w = 0; w < 200000 && !(done1_seen && done8_seen); w = w + 1) @(posedge clk);
        end
        check(done1_seen && done8_seen, "both engines finish");
        repeat (5) @(posedge clk);

        $display("OUTSTANDING=1 cycles=%0d beats=%0d | OUTSTANDING=8 cycles=%0d beats=%0d | mismatches=%0d",
                 cy1, br1, cy8, br8, mismatches);
        check(br1 == BURSTS*BURST, "1-outstanding read all beats");
        check(br8 == BURSTS*BURST, "8-outstanding read all beats");
        check(mismatches == 0, "8-outstanding data matches pattern");
        check(cy8 < cy1, "more outstanding hides latency (fewer cycles)");

        if (errors == 0) $display("PASS: ddr3_axi_rdma all checks");
        else $display("FAIL: ddr3_axi_rdma %0d errors", errors);
        $finish;
    end
endmodule
