`timescale 1ns/1ps

// Video-only first-stage shared-main integration. Exposes UI clock/reset for
// later evidence hookup; client1 is intentionally idle IN THIS configuration.
// The lower video_memory_fabric has a real evidence AXI interface tested with
// ddr_evidence_queued. This wrapper instantiates exactly one board MIG.
module ddr3_shared_video_ctrl #(
    parameter integer FIFO_DW=16,FIFO_ADDR_DEPTH=64,
    parameter [29:0] WR_BYTE_ADDR_BEGIN=0,WR_BYTE_ADDR_END=30'h1c1fff,
    parameter [29:0] RD_BYTE_ADDR_BEGIN=0,RD_BYTE_ADDR_END=30'h1c1fff
)(
    input wire ddr3_clk200m,ddr3_rst_n,
    output wire ddr3_init_done,
    output wire shared_ui_clk,shared_ui_rst,
    input wire wrfifo_clr,wrfifo_clk,wrfifo_wren,
    input wire [FIFO_DW-1:0] wrfifo_din,
    output wire wrfifo_full,
    output wire [15:0] wrfifo_wr_cnt,
    input wire rdfifo_clr,rdfifo_clk,rdfifo_rden,
    output wire [FIFO_DW-1:0] rdfifo_dout,
    output wire rdfifo_empty,
    output wire [15:0] rdfifo_rd_cnt,
    output wire [31:0] source_overflow,display_underflow,
    output wire [9:0] source_high,display_low,
    output wire [3:0] video_fault,protocol_fault,
    inout wire [31:0] ddr3_dq,
    inout wire [3:0] ddr3_dqs_n,ddr3_dqs_p,
    output wire [14:0] ddr3_addr,
    output wire [2:0] ddr3_ba,
    output wire ddr3_ras_n,ddr3_cas_n,ddr3_we_n,ddr3_reset_n,
    output wire [0:0] ddr3_ck_p,ddr3_ck_n,ddr3_cke,ddr3_cs_n,ddr3_odt,
    output wire [3:0] ddr3_dm
);
    wire ui_clk,ui_clk_sync_rst,mmcm_locked,init_calib_complete;
    wire [3:0] m_axi_awid,m_axi_arid,m_axi_bid,m_axi_rid;
    wire [29:0] m_axi_awaddr,m_axi_araddr;
    wire [7:0] m_axi_awlen,m_axi_arlen;
    wire [2:0] m_axi_awsize,m_axi_arsize,m_axi_awprot,m_axi_arprot;
    wire [1:0] m_axi_awburst,m_axi_arburst,m_axi_bresp,m_axi_rresp;
    wire m_axi_awlock,m_axi_arlock;
    wire [3:0] m_axi_awcache,m_axi_arcache,m_axi_awqos,m_axi_arqos;
    wire m_axi_awvalid,m_axi_arvalid,m_axi_awready,m_axi_arready,m_axi_wlast,m_axi_wvalid,m_axi_wready;
    wire m_axi_bvalid,m_axi_bready,m_axi_rlast,m_axi_rvalid,m_axi_rready;
    wire [127:0] m_axi_wdata,m_axi_rdata;
    wire [15:0] m_axi_wstrb;
    assign shared_ui_clk=ui_clk;
    assign shared_ui_rst=ui_clk_sync_rst || !init_calib_complete;
    assign ddr3_init_done=mmcm_locked && init_calib_complete;
    video_memory_fabric #(.WR_BEGIN(WR_BYTE_ADDR_BEGIN),.WR_END_EXCLUSIVE(WR_BYTE_ADDR_END+30'd1),
        .RD_BEGIN(RD_BYTE_ADDR_BEGIN),.RD_END_EXCLUSIVE(RD_BYTE_ADDR_END+30'd1)) fabric (
        .clk(ui_clk),.rst(shared_ui_rst),.wr_enable(1'b1),.rd_enable(1'b1),
        .wrfifo_clk(wrfifo_clk),.wrfifo_clr(wrfifo_clr),.wrfifo_wren(wrfifo_wren),.wrfifo_din(wrfifo_din),
        .wrfifo_full(wrfifo_full),.wrfifo_wr_cnt(wrfifo_wr_cnt),
        .rdfifo_clk(rdfifo_clk),.rdfifo_clr(rdfifo_clr),.rdfifo_rden(rdfifo_rden),.rdfifo_dout(rdfifo_dout),
        .rdfifo_empty(rdfifo_empty),.rdfifo_rd_cnt(rdfifo_rd_cnt),
        .source_overflow(source_overflow),.display_underflow(display_underflow),.source_high(source_high),.display_low(display_low),
        .video_fault(video_fault),.protocol_fault(protocol_fault),
        .e_awid(4'd0),.e_arid(4'd0),.e_awaddr(30'd0),.e_araddr(30'd0),.e_awlen(8'd0),.e_arlen(8'd0),
        .e_awsize(3'd4),.e_arsize(3'd4),.e_awburst(2'd1),.e_arburst(2'd1),.e_awvalid(1'b0),.e_arvalid(1'b0),
        .e_wdata(128'd0),.e_wstrb(16'd0),.e_wlast(1'b0),.e_wvalid(1'b0),.e_bready(1'b1),.e_rready(1'b1),
        .m_axi_awid(m_axi_awid),.m_axi_awaddr(m_axi_awaddr),.m_axi_awlen(m_axi_awlen),.m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),.m_axi_awlock(m_axi_awlock),.m_axi_awcache(m_axi_awcache),.m_axi_awprot(m_axi_awprot),.m_axi_awqos(m_axi_awqos),
        .m_axi_awvalid(m_axi_awvalid),.m_axi_awready(m_axi_awready),.m_axi_wdata(m_axi_wdata),.m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),.m_axi_wvalid(m_axi_wvalid),.m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid),.m_axi_bresp(m_axi_bresp),.m_axi_bvalid(m_axi_bvalid),.m_axi_bready(m_axi_bready),
        .m_axi_arid(m_axi_arid),.m_axi_araddr(m_axi_araddr),.m_axi_arlen(m_axi_arlen),.m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),.m_axi_arlock(m_axi_arlock),.m_axi_arcache(m_axi_arcache),.m_axi_arprot(m_axi_arprot),.m_axi_arqos(m_axi_arqos),
        .m_axi_arvalid(m_axi_arvalid),.m_axi_arready(m_axi_arready),.m_axi_rid(m_axi_rid),.m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),.m_axi_rlast(m_axi_rlast),.m_axi_rvalid(m_axi_rvalid),.m_axi_rready(m_axi_rready));
    mig_7series_0 u_mig_7series_0 (
        .ddr3_addr(ddr3_addr),.ddr3_ba(ddr3_ba),.ddr3_cas_n(ddr3_cas_n),.ddr3_ck_n(ddr3_ck_n),.ddr3_ck_p(ddr3_ck_p),
        .ddr3_cke(ddr3_cke),.ddr3_ras_n(ddr3_ras_n),.ddr3_reset_n(ddr3_reset_n),.ddr3_we_n(ddr3_we_n),
        .ddr3_dq(ddr3_dq),.ddr3_dqs_n(ddr3_dqs_n),.ddr3_dqs_p(ddr3_dqs_p),.ddr3_cs_n(ddr3_cs_n),.ddr3_dm(ddr3_dm),.ddr3_odt(ddr3_odt),
        .init_calib_complete(init_calib_complete),.ui_clk(ui_clk),.ui_clk_sync_rst(ui_clk_sync_rst),.mmcm_locked(mmcm_locked),
        .aresetn(ddr3_rst_n),.sys_clk_i(ddr3_clk200m),.sys_rst(ddr3_rst_n),.device_temp(),
        .app_sr_req(1'b0),.app_ref_req(1'b0),.app_zq_req(1'b0),.app_sr_active(),.app_ref_ack(),.app_zq_ack(),
        .s_axi_awid(m_axi_awid),.s_axi_awaddr(m_axi_awaddr),.s_axi_awlen(m_axi_awlen),.s_axi_awsize(m_axi_awsize),
        .s_axi_awburst(m_axi_awburst),.s_axi_awlock(m_axi_awlock),.s_axi_awcache(m_axi_awcache),.s_axi_awprot(m_axi_awprot),.s_axi_awqos(m_axi_awqos),
        .s_axi_awvalid(m_axi_awvalid),.s_axi_awready(m_axi_awready),.s_axi_wdata(m_axi_wdata),.s_axi_wstrb(m_axi_wstrb),
        .s_axi_wlast(m_axi_wlast),.s_axi_wvalid(m_axi_wvalid),.s_axi_wready(m_axi_wready),
        .s_axi_bid(m_axi_bid),.s_axi_bresp(m_axi_bresp),.s_axi_bvalid(m_axi_bvalid),.s_axi_bready(m_axi_bready),
        .s_axi_arid(m_axi_arid),.s_axi_araddr(m_axi_araddr),.s_axi_arlen(m_axi_arlen),.s_axi_arsize(m_axi_arsize),
        .s_axi_arburst(m_axi_arburst),.s_axi_arlock(m_axi_arlock),.s_axi_arcache(m_axi_arcache),.s_axi_arprot(m_axi_arprot),.s_axi_arqos(m_axi_arqos),
        .s_axi_arvalid(m_axi_arvalid),.s_axi_arready(m_axi_arready),.s_axi_rid(m_axi_rid),.s_axi_rdata(m_axi_rdata),
        .s_axi_rresp(m_axi_rresp),.s_axi_rlast(m_axi_rlast),.s_axi_rvalid(m_axi_rvalid),.s_axi_rready(m_axi_rready));
    // synthesis translate_off
    initial if(FIFO_DW!=16 || FIFO_ADDR_DEPTH!=64) $fatal(1,"FAIL: wrapper requires existing board FIFO configuration");
    // synthesis translate_on
endmodule
