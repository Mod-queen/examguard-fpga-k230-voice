`timescale 1ns/1ps

// Self-checking TB for the AXI DDR self-test master, against a behavioral
// AXI4 slave memory with random wait states. Verifies pattern integrity,
// counters, and that a corrupted location raises error_count.
module ddr3_axi_selftest_tb;
    localparam integer DW = 128, AW = 30, IW = 4, BURST = 16;
    localparam integer BEATS = 8 * BURST;   // 8 bursts

    reg clk = 0, rst = 1;
    reg start = 0;
    reg [AW-1:0] base_addr = 0;
    reg [15:0]   burst_count = 8;

    wire [IW-1:0] awid; wire [AW-1:0] awaddr; wire [7:0] awlen;
    wire [2:0] awsize; wire [1:0] awburst; wire awvalid;
    reg awready;
    wire [DW-1:0] wdata; wire [DW/8-1:0] wstrb; wire wlast, wvalid;
    reg wready;
    reg [IW-1:0] bid = 0; reg [1:0] bresp = 0; reg bvalid = 0;
    wire bready;
    wire [IW-1:0] arid; wire [AW-1:0] araddr; wire [7:0] arlen;
    wire [2:0] arsize; wire [1:0] arburst; wire arvalid;
    reg arready;
    wire rready;
    wire [IW-1:0] rid;
    wire [DW-1:0] rdata;
    wire [1:0]    rresp;
    wire          rlast;
    wire          rvalid;

    wire busy, done;
    wire [31:0] error_count, write_cycles, read_cycles, beats_written, beats_read;

    integer errors = 0;

    ddr3_axi_selftest #(.DATA_WIDTH(DW), .ADDR_WIDTH(AW), .ID_WIDTH(IW), .BURST(BURST)) dut (
        .clk(clk), .rst(rst), .start(start), .base_addr(base_addr), .burst_count(burst_count),
        .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
        .m_axi_awburst(awburst), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast), .m_axi_wvalid(wvalid),
        .m_axi_wready(wready),
        .m_axi_bid(bid), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
        .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize),
        .m_axi_arburst(arburst), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast),
        .m_axi_rvalid(rvalid), .m_axi_rready(rready),
        .busy(busy), .done(done), .error_count(error_count), .write_cycles(write_cycles),
        .read_cycles(read_cycles), .beats_written(beats_written), .beats_read(beats_read));

    always #5 clk = ~clk;

    // ---- Behavioral AXI4 slave memory -------------------------------------
    reg [DW-1:0] mem [0:65535];
    reg [AW-1:0] w_addr = 0; reg [7:0] w_len = 0; reg [7:0] w_beat = 0; reg w_active = 0;
    reg [AW-1:0] r_addr = 0; reg [7:0] r_len = 0; reg [7:0] r_beat = 0; reg r_active = 0;
    reg corrupt_enable = 0;
    reg [AW-1:0] corrupt_addr = 30'd256;   // second burst, first beat
    reg [31:0] prng = 32'hACE1_2345;
    wire [31:0] prng_next = {prng[30:0], prng[31]^prng[21]};

    // Read path is combinational so rvalid/rdata/rlast always agree.
    assign rid    = {IW{1'b0}};
    assign rdata  = mem[(r_addr>>4) + r_beat];
    assign rresp  = 2'b00;
    assign rlast  = (r_beat == r_len);
    assign rvalid = r_active && ~prng[29];

    integer wi;
    always @(posedge clk) begin
        if (rst) begin
            awready <= 0; wready <= 0; bvalid <= 0; arready <= 0;
            w_active <= 0; r_active <= 0; w_beat <= 0; r_beat <= 0; prng <= 32'h1;
            w_len <= 0; r_len <= 0; w_addr <= 0; r_addr <= 0;
        end else begin
            prng <= prng_next;
            // Write address channel.
            awready <= !w_active ? ~prng[0] : 1'b0;
            if (awvalid && awready) begin
                w_addr <= awaddr; w_len <= awlen; w_beat <= 0; w_active <= 1'b1;
            end
            // Write data channel.
            wready <= w_active ? ~prng[7] : 1'b0;
            if (w_active && wvalid && wready) begin
                wi = (w_addr >> 4) + w_beat;
                mem[wi] <= (corrupt_enable && (w_addr + w_beat*16) == corrupt_addr)
                           ? ~wdata : wdata;
                if (w_beat == w_len) begin w_active <= 1'b0; bvalid <= 1'b1; end
                else w_beat <= w_beat + 8'd1;
            end
            if (bvalid && bready) bvalid <= 1'b0;
            // Read address channel.
            arready <= !r_active ? ~prng[13] : 1'b0;
            if (arvalid && arready) begin
                r_addr <= araddr; r_len <= arlen; r_beat <= 0; r_active <= 1'b1;
            end
            // Read data advance.
            if (r_active && rvalid && rready) begin
                if (r_beat == r_len) r_active <= 1'b0;
                else r_beat <= r_beat + 8'd1;
            end
        end
    end

    task check(input cond, input [255:0] name);
        begin if (!cond) begin errors = errors + 1; $display("FAIL: %0s", name); end end
    endtask

    task run(input integer timeout);
        integer c;
        begin
            start = 1; @(posedge clk); start = 0;
            c = 0;
            while (!done && c < timeout) begin @(posedge clk); c = c + 1; end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk);

        corrupt_enable = 0;
        run(20000);
        check(done, "clean run completes");
        check(error_count == 0, "clean run has no errors");
        check(beats_written == BEATS, "all beats written");
        check(beats_read == BEATS, "all beats read");
        check(write_cycles > 0 && read_cycles > 0, "cycle counters advanced");

        repeat (5) @(posedge clk);
        corrupt_enable = 1;
        run(20000);
        check(done, "corrupt run completes");
        check(error_count >= 1, "corruption is detected");

        if (errors == 0) $display("PASS: ddr3_axi_selftest all checks");
        else $display("FAIL: ddr3_axi_selftest %0d errors", errors);
        $finish;
    end
endmodule
