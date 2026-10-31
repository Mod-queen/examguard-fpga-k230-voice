`timescale 1ns/1ps

// Audit the UNMODIFIED vendor video address machines. This is a contract audit,
// not a video/shared-MIG acceptance test. First exercise normal single bursts;
// then deliberately reproduce their addr_clr / VALID-stalled incompatibility.
// No FIFO-IP model is used: FIFO endpoints provide constant valid data/free
// space. Actual video FIFO clear/drain and display deadlines remain untested.
module legacy_video_axi_contract_tb;
    reg clk=0,reset=1,addr_clr=0;
    always #5 clk=~clk;
    wire wrreq,rdreq;
    wire [127:0] fifo_wrdata;
    wire [29:0] awaddr,araddr;
    wire [7:0] awlen,arlen;
    wire [3:0] awid,arid;
    wire [2:0] awsize,arsize;
    wire [1:0] awburst,arburst;
    wire awlock,arlock;
    wire [3:0] awcache,awqos,awregion,arcache,arqos,arregion;
    wire [2:0] awprot,arprot;
    wire awvalid,arvalid,wvalid,wlast,bready,rready;
    wire [127:0] wdata;
    wire [15:0] wstrb;
    reg awready=0,arready=0,wready=0,bvalid=0,rvalid=0,rlast=0;
    reg [127:0] rdata=0;
    fifo_to_axi4 #(.AXI_DATA_WIDTH(128),.AXI_ADDR_WIDTH(30),.AXI_BURST_LEN(31),
        .FIFO_ADDR_WIDTH(6),.WR_AXI_BYTE_ADDR_END(8191)) writer (
        .clk(clk),.reset(reset),.addr_clr(addr_clr),.fifo_rdreq(wrreq),
        .fifo_rddata(128'h1234),.fifo_empty(1'b0),.fifo_rd_cnt(6'd63),.fifo_rst_busy(1'b0),
        .m_axi_awid(awid),.m_axi_awaddr(awaddr),.m_axi_awlen(awlen),.m_axi_awsize(awsize),
        .m_axi_awburst(awburst),.m_axi_awlock(awlock),.m_axi_awcache(awcache),.m_axi_awprot(awprot),
        .m_axi_awqos(awqos),.m_axi_awregion(awregion),.m_axi_awvalid(awvalid),.m_axi_awready(awready),
        .m_axi_wdata(wdata),.m_axi_wstrb(wstrb),.m_axi_wlast(wlast),.m_axi_wvalid(wvalid),.m_axi_wready(wready),
        .m_axi_bid(4'd0),.m_axi_bresp(2'd0),.m_axi_bvalid(bvalid),.m_axi_bready(bready));
    axi4_to_fifo #(.AXI_DATA_WIDTH(128),.AXI_ADDR_WIDTH(30),.AXI_BURST_LEN(31),
        .FIFO_ADDR_WIDTH(6),.RD_AXI_BYTE_ADDR_END(8191)) reader (
        .clk(clk),.reset(reset),.addr_clr(addr_clr),.fifo_wrreq(rdreq),.fifo_wrdata(fifo_wrdata),
        .fifo_alfull(1'b0),.fifo_wr_cnt(6'd0),.fifo_rst_busy(1'b0),
        .m_axi_arid(arid),.m_axi_araddr(araddr),.m_axi_arlen(arlen),.m_axi_arsize(arsize),
        .m_axi_arburst(arburst),.m_axi_arlock(arlock),.m_axi_arcache(arcache),.m_axi_arprot(arprot),
        .m_axi_arqos(arqos),.m_axi_arregion(arregion),.m_axi_arvalid(arvalid),.m_axi_arready(arready),
        .m_axi_rid(4'd0),.m_axi_rdata(rdata),.m_axi_rresp(2'd0),.m_axi_rlast(rlast),.m_axi_rvalid(rvalid),.m_axi_rready(rready));
    integer writes=0,reads=0,delivered=0,i;
    always @(posedge clk) if(!reset) begin
        if(wvalid && wready) writes=writes+1;
        if(rvalid && rready) reads=reads+1;
        if(rdreq) delivered=delivered+1;
    end
    reg [29:0] old_aw,old_ar;
    initial begin
        repeat(5) @(negedge clk);reset=0;
        wait(awvalid && arvalid);@(negedge clk);awready=1;arready=1;wready=1;
        @(negedge clk);awready=0;arready=0;
        for(i=0;i<32;i=i+1) begin rvalid=1;rlast=i==31;rdata=i;@(negedge clk);end
        rvalid=0;rlast=0;
        wait(writes==32);@(negedge clk);wready=0;bvalid=1;
        @(negedge clk);bvalid=0;
        wait(awvalid && arvalid);@(negedge clk);
        if(awaddr!=512 || araddr!=512 || writes!=32 || reads!=32 || delivered!=32)
            $fatal(1,"FAIL: video normal contract did not reach second burst");
        old_aw=awaddr;old_ar=araddr;
        // Both address channels are VALID with READY=0. AXI requires address
        // retention here; unmodified video RTL resets addresses immediately.
        addr_clr=1;@(negedge clk);
        if(!awvalid || !arvalid || awready || arready || awaddr==old_aw || araddr==old_ar || awaddr!=0 || araddr!=0)
            $fatal(1,"FAIL: expected legacy address-clear hazard not reproduced");
        $display("AUDIT_CONFIRMED: addr_clr changed stalled AW/AR from 0x%h/0x%h to 0x%h/0x%h",old_aw,old_ar,awaddr,araddr);
        // Existing read path intentionally discards read beats at frame clear.
        // Confirm this behaviour instead of assuming each R handshake reaches FIFO.
        addr_clr=0;arready=1;@(negedge clk);arready=0;rvalid=1;rdata=128'hbeef;
        @(negedge clk);rvalid=0;
        repeat(3) @(negedge clk);
        if(reads!=33 || delivered!=32) $fatal(1,"FAIL: expected read-clear discard not reproduced");
        $display("AUDIT_CONFIRMED: frame-clear drain accepted R beat without publishing it to video FIFO");
        $display("PASS: legacy_video_axi_contract audit checks (known incompatibilities confirmed, NOT acceptance)");$finish;
    end
    initial begin #100000;$fatal(1,"FAIL: video contract audit timeout");end
endmodule
