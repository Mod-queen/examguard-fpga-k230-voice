`timescale 1ns/1ps

// UI-domain shared port assembly. Client0 is the physical video FIFO path;
// client1 is an external evidence AXI master in the SAME UI domain. The actual
// MIG lives one wrapper above so this exact assembly can be tested with memory.
module video_memory_fabric #(
    parameter [29:0] WR_BEGIN=0,WR_END_EXCLUSIVE=30'h1c2000,
    parameter [29:0] RD_BEGIN=0,RD_END_EXCLUSIVE=30'h1c2000,
    parameter integer VIDEO_QUOTA=3,
    parameter integer E_READ_BUFFER=1
)(
    input wire clk,rst,wr_enable,rd_enable,
    input wire wrfifo_clk,wrfifo_clr,wrfifo_wren,
    input wire [15:0] wrfifo_din,
    output wire wrfifo_full,
    output wire [15:0] wrfifo_wr_cnt,
    input wire rdfifo_clk,rdfifo_clr,rdfifo_rden,
    output wire [15:0] rdfifo_dout,
    output wire rdfifo_empty,
    output wire [15:0] rdfifo_rd_cnt,
    output wire [31:0] source_overflow,display_underflow,
    output wire [9:0] source_high,display_low,
    output wire [3:0] video_fault,protocol_fault,
    output wire evidence_buffer_fault,
    output wire [31:0] video_write_beats,video_read_beats,video_published_beats,
    output wire [63:0] write_grants,read_grants,write_wait_max,read_wait_max,
    input wire [3:0] e_awid,e_arid,
    input wire [29:0] e_awaddr,e_araddr,
    input wire [7:0] e_awlen,e_arlen,
    input wire [2:0] e_awsize,e_arsize,
    input wire [1:0] e_awburst,e_arburst,
    input wire e_awvalid,e_arvalid,
    output wire e_awready,e_arready,
    input wire [127:0] e_wdata,
    input wire [15:0] e_wstrb,
    input wire e_wlast,e_wvalid,
    output wire e_wready,
    output wire [3:0] e_bid,e_rid,
    output wire [1:0] e_bresp,e_rresp,
    output wire e_bvalid,e_rvalid,e_rlast,
    output wire [127:0] e_rdata,
    input wire e_bready,e_rready,
    output wire [3:0] m_axi_awid,m_axi_arid,
    output wire [29:0] m_axi_awaddr,m_axi_araddr,
    output wire [7:0] m_axi_awlen,m_axi_arlen,
    output wire [2:0] m_axi_awsize,m_axi_arsize,m_axi_awprot,m_axi_arprot,
    output wire [1:0] m_axi_awburst,m_axi_arburst,
    output wire m_axi_awlock,m_axi_arlock,
    output wire [3:0] m_axi_awcache,m_axi_arcache,m_axi_awqos,m_axi_arqos,
    output wire m_axi_awvalid,m_axi_arvalid,
    input wire m_axi_awready,m_axi_arready,
    output wire [127:0] m_axi_wdata,
    output wire [15:0] m_axi_wstrb,
    output wire m_axi_wlast,m_axi_wvalid,
    input wire m_axi_wready,
    input wire [3:0] m_axi_bid,m_axi_rid,
    input wire [1:0] m_axi_bresp,m_axi_rresp,
    input wire m_axi_bvalid,m_axi_rvalid,m_axi_rlast,
    input wire [127:0] m_axi_rdata,
    output wire m_axi_bready,m_axi_rready
);
    wire [7:0] s_axi_awid,s_axi_bid,s_axi_arid,s_axi_rid;
    wire [59:0] s_axi_awaddr,s_axi_araddr;
    wire [15:0] s_axi_awlen,s_axi_arlen;
    wire [5:0] s_axi_awsize,s_axi_awprot,s_axi_arsize,s_axi_arprot;
    wire [3:0] s_axi_awburst,s_axi_arburst,s_axi_bresp,s_axi_rresp;
    wire [1:0] s_axi_awlock,s_axi_arlock;
    wire [7:0] s_axi_awcache,s_axi_awqos,s_axi_arcache,s_axi_arqos;
    wire [1:0] s_axi_awvalid,s_axi_awready,s_axi_wlast,s_axi_wvalid,s_axi_wready;
    wire [1:0] s_axi_bvalid,s_axi_bready,s_axi_arvalid,s_axi_arready,s_axi_rlast,s_axi_rvalid,s_axi_rready;
    wire [255:0] s_axi_wdata,s_axi_rdata;
    wire [31:0] s_axi_wstrb;
    assign s_axi_awlock=0;assign s_axi_arlock=0;
    assign s_axi_awcache=0;assign s_axi_arcache=0;assign s_axi_awprot=0;assign s_axi_arprot=0;
    assign s_axi_awqos={4'd0,4'd9};assign s_axi_arqos={4'd0,4'd9};
    assign s_axi_awid[7:4]=e_awid;assign s_axi_arid[7:4]=e_arid;
    assign s_axi_awaddr[59:30]=e_awaddr;assign s_axi_araddr[59:30]=e_araddr;
    assign s_axi_awlen[15:8]=e_awlen;assign s_axi_arlen[15:8]=e_arlen;
    assign s_axi_awsize[5:3]=e_awsize;assign s_axi_arsize[5:3]=e_arsize;
    assign s_axi_awburst[3:2]=e_awburst;assign s_axi_arburst[3:2]=e_arburst;
    assign s_axi_awvalid[1]=e_awvalid;
    assign e_awready=s_axi_awready[1];
    assign s_axi_wdata[255:128]=e_wdata;assign s_axi_wstrb[31:16]=e_wstrb;
    assign s_axi_wlast[1]=e_wlast;assign s_axi_wvalid[1]=e_wvalid;assign e_wready=s_axi_wready[1];
    assign e_bid=s_axi_bid[7:4];assign e_bresp=s_axi_bresp[3:2];assign e_bvalid=s_axi_bvalid[1];
    assign s_axi_bready[1]=e_bready;
    generate if(E_READ_BUFFER) begin : buffered_evidence_read
        wire ar_open;
        axi_read_burst_buffer buffer (
            .clk(clk),.rst(rst),.ar_fire(s_axi_arvalid[1] && s_axi_arready[1]),.ar_open(ar_open),
            .in_data(s_axi_rdata[255:128]),.in_id(s_axi_rid[7:4]),.in_resp(s_axi_rresp[3:2]),
            .in_last(s_axi_rlast[1]),.in_valid(s_axi_rvalid[1]),.in_ready(s_axi_rready[1]),
            .out_data(e_rdata),.out_id(e_rid),.out_resp(e_rresp),.out_last(e_rlast),.out_valid(e_rvalid),.out_ready(e_rready),
            .overflow_fault(evidence_buffer_fault));
        assign s_axi_arvalid[1]=e_arvalid && ar_open;
        assign e_arready=s_axi_arready[1] && ar_open;
    end else begin : unbuffered_evidence_read
        assign evidence_buffer_fault=1'b0;
        assign s_axi_arvalid[1]=e_arvalid;assign e_arready=s_axi_arready[1];
        assign e_rid=s_axi_rid[7:4];assign e_rresp=s_axi_rresp[3:2];assign e_rvalid=s_axi_rvalid[1];
        assign e_rdata=s_axi_rdata[255:128];assign e_rlast=s_axi_rlast[1];assign s_axi_rready[1]=e_rready;
    end endgenerate
    video_fifo_axi_port #(.WR_BEGIN(WR_BEGIN),.WR_END_EXCLUSIVE(WR_END_EXCLUSIVE),
        .RD_BEGIN(RD_BEGIN),.RD_END_EXCLUSIVE(RD_END_EXCLUSIVE)) video (
        .clk(clk),.rst(rst),.wr_enable(wr_enable),.rd_enable(rd_enable),
        .wrfifo_clk(wrfifo_clk),.wrfifo_clr(wrfifo_clr),.wrfifo_wren(wrfifo_wren),.wrfifo_din(wrfifo_din),
        .wrfifo_full(wrfifo_full),.wrfifo_wr_cnt(wrfifo_wr_cnt),
        .rdfifo_clk(rdfifo_clk),.rdfifo_clr(rdfifo_clr),.rdfifo_rden(rdfifo_rden),.rdfifo_dout(rdfifo_dout),
        .rdfifo_empty(rdfifo_empty),.rdfifo_rd_cnt(rdfifo_rd_cnt),
        .source_overflow(source_overflow),.display_underflow(display_underflow),.source_high(source_high),.display_low(display_low),
        .video_fault(video_fault),.video_write_beats(video_write_beats),.video_read_beats(video_read_beats),
        .video_published_beats(video_published_beats),
        .m_axi_awid(s_axi_awid[3:0]),.m_axi_awaddr(s_axi_awaddr[29:0]),.m_axi_awlen(s_axi_awlen[7:0]),
        .m_axi_awsize(s_axi_awsize[2:0]),.m_axi_awburst(s_axi_awburst[1:0]),.m_axi_awvalid(s_axi_awvalid[0]),.m_axi_awready(s_axi_awready[0]),
        .m_axi_wdata(s_axi_wdata[127:0]),.m_axi_wstrb(s_axi_wstrb[15:0]),.m_axi_wlast(s_axi_wlast[0]),
        .m_axi_wvalid(s_axi_wvalid[0]),.m_axi_wready(s_axi_wready[0]),
        .m_axi_bid(s_axi_bid[3:0]),.m_axi_bresp(s_axi_bresp[1:0]),.m_axi_bvalid(s_axi_bvalid[0]),.m_axi_bready(s_axi_bready[0]),
        .m_axi_arid(s_axi_arid[3:0]),.m_axi_araddr(s_axi_araddr[29:0]),.m_axi_arlen(s_axi_arlen[7:0]),
        .m_axi_arsize(s_axi_arsize[2:0]),.m_axi_arburst(s_axi_arburst[1:0]),.m_axi_arvalid(s_axi_arvalid[0]),.m_axi_arready(s_axi_arready[0]),
        .m_axi_rid(s_axi_rid[3:0]),.m_axi_rdata(s_axi_rdata[127:0]),.m_axi_rresp(s_axi_rresp[1:0]),
        .m_axi_rlast(s_axi_rlast[0]),.m_axi_rvalid(s_axi_rvalid[0]),.m_axi_rready(s_axi_rready[0]));
    axi_2client_arbiter #(.VIDEO_QUOTA(VIDEO_QUOTA)) arbiter (
        .clk(clk),.rst(rst),
        .s_axi_awid(s_axi_awid),.s_axi_awaddr(s_axi_awaddr),.s_axi_awlen(s_axi_awlen),.s_axi_awsize(s_axi_awsize),
        .s_axi_awburst(s_axi_awburst),.s_axi_awlock(s_axi_awlock),.s_axi_awcache(s_axi_awcache),.s_axi_awprot(s_axi_awprot),
        .s_axi_awqos(s_axi_awqos),.s_axi_awvalid(s_axi_awvalid),.s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),.s_axi_wstrb(s_axi_wstrb),.s_axi_wlast(s_axi_wlast),.s_axi_wvalid(s_axi_wvalid),.s_axi_wready(s_axi_wready),
        .s_axi_bid(s_axi_bid),.s_axi_bresp(s_axi_bresp),.s_axi_bvalid(s_axi_bvalid),.s_axi_bready(s_axi_bready),
        .s_axi_arid(s_axi_arid),.s_axi_araddr(s_axi_araddr),.s_axi_arlen(s_axi_arlen),.s_axi_arsize(s_axi_arsize),
        .s_axi_arburst(s_axi_arburst),.s_axi_arlock(s_axi_arlock),.s_axi_arcache(s_axi_arcache),.s_axi_arprot(s_axi_arprot),
        .s_axi_arqos(s_axi_arqos),.s_axi_arvalid(s_axi_arvalid),.s_axi_arready(s_axi_arready),
        .s_axi_rid(s_axi_rid),.s_axi_rdata(s_axi_rdata),.s_axi_rresp(s_axi_rresp),.s_axi_rlast(s_axi_rlast),.s_axi_rvalid(s_axi_rvalid),.s_axi_rready(s_axi_rready),
        .m_axi_awid(m_axi_awid),.m_axi_awaddr(m_axi_awaddr),.m_axi_awlen(m_axi_awlen),.m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),.m_axi_awlock(m_axi_awlock),.m_axi_awcache(m_axi_awcache),.m_axi_awprot(m_axi_awprot),.m_axi_awqos(m_axi_awqos),
        .m_axi_awvalid(m_axi_awvalid),.m_axi_awready(m_axi_awready),.m_axi_wdata(m_axi_wdata),.m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),.m_axi_wvalid(m_axi_wvalid),.m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid),.m_axi_bresp(m_axi_bresp),.m_axi_bvalid(m_axi_bvalid),.m_axi_bready(m_axi_bready),
        .m_axi_arid(m_axi_arid),.m_axi_araddr(m_axi_araddr),.m_axi_arlen(m_axi_arlen),.m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),.m_axi_arlock(m_axi_arlock),.m_axi_arcache(m_axi_arcache),.m_axi_arprot(m_axi_arprot),.m_axi_arqos(m_axi_arqos),
        .m_axi_arvalid(m_axi_arvalid),.m_axi_arready(m_axi_arready),.m_axi_rid(m_axi_rid),.m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),.m_axi_rlast(m_axi_rlast),.m_axi_rvalid(m_axi_rvalid),.m_axi_rready(m_axi_rready),
        .protocol_fault(protocol_fault),.write_grants(write_grants),.read_grants(read_grants),
        .write_wait_max(write_wait_max),.read_wait_max(read_wait_max));
endmodule
