`timescale 1ns/1ps

// Synthesizable replacement video port for the isolated shared-main snapshot.
// Uses the board's existing asymmetric STANDARD FIFO IPs. Async assert,
// clock-local release stretches even a one-pixel SOF pulse; client_clear also
// holds while the FIFO UI reset_busy is high. rst is common AXI/UI reset;
// wrfifo_clr/rdfifo_clr are local frame-epoch resets, never AXI reset.
module video_fifo_axi_port #(
    parameter [29:0] WR_BEGIN=0, WR_END_EXCLUSIVE=30'h1c2000,
    parameter [29:0] RD_BEGIN=0, RD_END_EXCLUSIVE=30'h1c2000
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
    output reg [31:0] source_overflow,display_underflow,
    output reg [9:0] source_high,display_low,
    output wire [3:0] video_fault,
    output wire [31:0] video_write_beats,video_read_beats,video_published_beats,
    output wire [3:0] m_axi_awid,
    output wire [29:0] m_axi_awaddr,
    output wire [7:0] m_axi_awlen,
    output wire [2:0] m_axi_awsize,
    output wire [1:0] m_axi_awburst,
    output wire m_axi_awvalid,
    input wire m_axi_awready,
    output wire [127:0] m_axi_wdata,
    output wire [15:0] m_axi_wstrb,
    output wire m_axi_wlast,m_axi_wvalid,
    input wire m_axi_wready,
    input wire [3:0] m_axi_bid,
    input wire [1:0] m_axi_bresp,
    input wire m_axi_bvalid,
    output wire m_axi_bready,
    output wire [3:0] m_axi_arid,
    output wire [29:0] m_axi_araddr,
    output wire [7:0] m_axi_arlen,
    output wire [2:0] m_axi_arsize,
    output wire [1:0] m_axi_arburst,
    output wire m_axi_arvalid,
    input wire m_axi_arready,
    input wire [3:0] m_axi_rid,
    input wire [127:0] m_axi_rdata,
    input wire [1:0] m_axi_rresp,
    input wire m_axi_rlast,m_axi_rvalid,
    output wire m_axi_rready
);
    wire wreset,rreset;
    video_epoch_clear w_fifo_reset(.ui_clk(wrfifo_clk),.ui_rst(rst),.source_clear(wrfifo_clr),
        .fifo_ui_rst_busy(1'b0),.client_clear(wreset));
    video_epoch_clear r_fifo_reset(.ui_clk(rdfifo_clk),.ui_rst(rst),.source_clear(rdfifo_clr),
        .fifo_ui_rst_busy(1'b0),.client_clear(rreset));
    wire w_ui_busy,w_source_busy,r_ui_busy,r_display_busy;
    wire wempty,rfull,wpop,rpush;
    wire [127:0] wdata,rdata;
    wire [5:0] w_ui_count,r_ui_count;
    wire [8:0] w_source_count,r_display_count;
    assign wrfifo_wr_cnt={7'd0,w_source_count};
    assign rdfifo_rd_cnt={7'd0,r_display_count};
    wr_ddr3_fifo wr_ddr3_fifo (
        .rst(wreset),.wr_clk(wrfifo_clk),.rd_clk(clk),.din(wrfifo_din),
        .wr_en(wrfifo_wren && !wreset && !w_source_busy),.rd_en(wpop),.dout(wdata),
        .full(wrfifo_full),.empty(wempty),.wr_data_count(w_source_count),.rd_data_count(w_ui_count),
        .wr_rst_busy(w_source_busy),.rd_rst_busy(w_ui_busy));
    rd_ddr3_fifo rd_ddr3_fifo (
        .rst(rreset),.wr_clk(clk),.rd_clk(rdfifo_clk),.din(rdata),.wr_en(rpush),
        .rd_en(rdfifo_rden && !rreset && !r_display_busy),.dout(rdfifo_dout),
        .full(rfull),.empty(rdfifo_empty),.wr_data_count(r_ui_count),.rd_data_count(r_display_count),
        .wr_rst_busy(r_ui_busy),.rd_rst_busy(r_display_busy));
    wire wclear,rclear;
    video_epoch_clear w_client_epoch(.ui_clk(clk),.ui_rst(rst),.source_clear(wreset),
        .fifo_ui_rst_busy(w_ui_busy),.client_clear(wclear));
    video_epoch_clear r_client_epoch(.ui_clk(clk),.ui_rst(rst),.source_clear(rreset),
        .fifo_ui_rst_busy(r_ui_busy),.client_clear(rclear));
    wire in_valid,in_ready,out_valid,out_ready;
    wire [127:0] in_data,out_data;
    video_fifo_stream_bridge bridge (
        .clk(clk),.rst(rst),.wr_clear(wclear),.rd_clear(rclear),
        .wrfifo_empty(wempty),.wrfifo_rst_busy(w_ui_busy),.wrfifo_dout(wdata),.wrfifo_rd_en(wpop),
        .in_valid(in_valid),.in_data(in_data),.in_ready(in_ready),.out_valid(out_valid),.out_data(out_data),.out_ready(out_ready),
        .rdfifo_full(rfull),.rdfifo_rst_busy(r_ui_busy),.rdfifo_wr_en(rpush),.rdfifo_din(rdata),
        .words_fetched(),.words_to_client(),.words_to_display(),.cancelled_words());
    video_axi_client #(.WR_BEGIN(WR_BEGIN),.WR_END_EXCLUSIVE(WR_END_EXCLUSIVE),
        .RD_BEGIN(RD_BEGIN),.RD_END_EXCLUSIVE(RD_END_EXCLUSIVE)) client (
        .clk(clk),.rst(rst),.wr_enable(wr_enable),.rd_enable(rd_enable),.wr_clear(wclear),.rd_clear(rclear),
        .in_valid(in_valid),.in_data(in_data),.in_ready(in_ready),.out_valid(out_valid),.out_data(out_data),.out_ready(out_ready),
        .fault(video_fault),.write_beats(video_write_beats),.read_beats(video_read_beats),.published_beats(video_published_beats),
        .m_axi_awid(m_axi_awid),.m_axi_awaddr(m_axi_awaddr),.m_axi_awlen(m_axi_awlen),.m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),.m_axi_awvalid(m_axi_awvalid),.m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),.m_axi_wstrb(m_axi_wstrb),.m_axi_wlast(m_axi_wlast),.m_axi_wvalid(m_axi_wvalid),.m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid),.m_axi_bresp(m_axi_bresp),.m_axi_bvalid(m_axi_bvalid),.m_axi_bready(m_axi_bready),
        .m_axi_arid(m_axi_arid),.m_axi_araddr(m_axi_araddr),.m_axi_arlen(m_axi_arlen),.m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),.m_axi_arvalid(m_axi_arvalid),.m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid),.m_axi_rdata(m_axi_rdata),.m_axi_rresp(m_axi_rresp),.m_axi_rlast(m_axi_rlast),.m_axi_rvalid(m_axi_rvalid),.m_axi_rready(m_axi_rready));
    function [31:0] inc_sat;
        input [31:0] n;
        begin inc_sat=n==32'hffffffff ? n : n+1'b1;end
    endfunction
    // Statistics remain in their native domains. A future telemetry bridge
    // must snapshot them coherently, not sample these buses directly in UI.
    always @(posedge wrfifo_clk or posedge rst) begin
        if(rst) begin source_overflow<=0;source_high<=0;end
        else if(!wreset && !w_source_busy) begin
            if(wrfifo_wren && wrfifo_full) source_overflow<=inc_sat(source_overflow);
            if({1'b0,w_source_count}>source_high) source_high<={1'b0,w_source_count};
        end
    end
    always @(posedge rdfifo_clk or posedge rst) begin
        if(rst) begin display_underflow<=0;display_low<=10'd512;end
        else if(!rreset && !r_display_busy && rdfifo_rden) begin
            if(rdfifo_empty) display_underflow<=inc_sat(display_underflow);
            if({1'b0,r_display_count}<display_low) display_low<={1'b0,r_display_count};
        end
    end
endmodule
