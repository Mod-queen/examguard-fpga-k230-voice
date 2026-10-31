`timescale 1ns/1ps
// TEST-ONLY substitute for MIG ports. Models independent raw calibration/UI
// readiness and AXI aresetn cancellation; NOT PHY/DDR training/electrical model.
// Only sim_evidence_wrapper_reset imports this instead of the real MIG IP.
module mig_7series_0(
    input wire sys_clk_i,sys_rst,aresetn,
    output wire ui_clk,
    output wire ui_clk_sync_rst,mmcm_locked,init_calib_complete,
    input wire app_sr_req,app_ref_req,app_zq_req,
    output wire app_sr_active,app_ref_ack,app_zq_ack,
    output wire [11:0] device_temp,
    output wire [96:0] board_monitor,
    inout wire [31:0] ddr3_dq,
    inout wire [3:0] ddr3_dqs_n,ddr3_dqs_p,
    output wire [14:0] ddr3_addr,
    output wire [2:0] ddr3_ba,
    output wire ddr3_ras_n,ddr3_cas_n,ddr3_we_n,ddr3_reset_n,
    output wire [0:0] ddr3_ck_p,ddr3_ck_n,ddr3_cke,ddr3_cs_n,ddr3_odt,
    output wire [3:0] ddr3_dm,
    input wire [3:0] s_axi_awid,s_axi_arid,
    input wire [29:0] s_axi_awaddr,s_axi_araddr,
    input wire [7:0] s_axi_awlen,s_axi_arlen,
    input wire [2:0] s_axi_awsize,s_axi_arsize,s_axi_awprot,s_axi_arprot,
    input wire [1:0] s_axi_awburst,s_axi_arburst,
    input wire s_axi_awlock,s_axi_arlock,
    input wire [3:0] s_axi_awcache,s_axi_arcache,s_axi_awqos,s_axi_arqos,
    input wire s_axi_awvalid,s_axi_arvalid,
    output wire s_axi_awready,s_axi_arready,
    input wire [127:0] s_axi_wdata,
    input wire [15:0] s_axi_wstrb,
    input wire s_axi_wlast,s_axi_wvalid,
    output wire s_axi_wready,
    output wire [3:0] s_axi_bid,s_axi_rid,
    output wire [1:0] s_axi_bresp,s_axi_rresp,
    output wire s_axi_bvalid,s_axi_rvalid,s_axi_rlast,
    output wire [127:0] s_axi_rdata,
    input wire s_axi_bready,s_axi_rready
);
    reg clock=0;
    always #5 clock=~clock;
    assign ui_clk=clock;
    reg [3:0] calibration=0;
    always @(posedge clock) if(!sys_rst) calibration<=0;else if(calibration<8) calibration<=calibration+1;
    assign init_calib_complete=calibration==8;
    assign ui_clk_sync_rst=!init_calib_complete;
    assign mmcm_locked=calibration>=4;
    assign device_temp=0;assign board_monitor=0;
    assign app_sr_active=0;assign app_ref_ack=0;assign app_zq_ack=0;
    assign ddr3_addr=0;assign ddr3_ba=0;assign ddr3_dm=0;
    assign {ddr3_ras_n,ddr3_cas_n,ddr3_we_n}=3'b111;
    assign ddr3_reset_n=sys_rst;assign ddr3_ck_p=clock;assign ddr3_ck_n=!clock;
    assign {ddr3_cke,ddr3_cs_n,ddr3_odt}=3'b000;
    reg hold_b=0;
    axi_frame_slave_model memory(.clk(clock),.rst(!aresetn || !init_calib_complete),.hold_b(hold_b),.inject_b(1'b0),.inject_r(1'b0),
        .m_axi_awid(s_axi_awid),.m_axi_awaddr(s_axi_awaddr),.m_axi_awlen(s_axi_awlen),.m_axi_awsize(s_axi_awsize),.m_axi_awburst(s_axi_awburst),.m_axi_awvalid(s_axi_awvalid),.m_axi_awready(s_axi_awready),
        .m_axi_wdata(s_axi_wdata),.m_axi_wstrb(s_axi_wstrb),.m_axi_wlast(s_axi_wlast),.m_axi_wvalid(s_axi_wvalid),.m_axi_wready(s_axi_wready),
        .m_axi_bid(s_axi_bid),.m_axi_bresp(s_axi_bresp),.m_axi_bvalid(s_axi_bvalid),.m_axi_bready(s_axi_bready),
        .m_axi_arid(s_axi_arid),.m_axi_araddr(s_axi_araddr),.m_axi_arlen(s_axi_arlen),.m_axi_arsize(s_axi_arsize),.m_axi_arburst(s_axi_arburst),.m_axi_arvalid(s_axi_arvalid),.m_axi_arready(s_axi_arready),
        .m_axi_rid(s_axi_rid),.m_axi_rdata(s_axi_rdata),.m_axi_rresp(s_axi_rresp),.m_axi_rlast(s_axi_rlast),.m_axi_rvalid(s_axi_rvalid),.m_axi_rready(s_axi_rready));
endmodule
