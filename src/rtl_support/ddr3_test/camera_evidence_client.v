`timescale 1ns/1ps

// Candidate evidence AXI CLIENT, no MIG here. Display-domain RGB grid/whole-frame
// guard -> async pixel FIFO -> UI-domain DDR ring; control-domain transaction
// ready/valid -> bundled CDC -> UI event queue -> held window/result consumers.
// Defaults are a CANDIDATE 320x180 / nominal10fps / 20pre+20post frame policy;
// retained frames, their metadata, and actual times define coverage, NOT a fixed
// +/-2s guarantee. Queued windows remain SERVICE-anchored, not event-time-exact.
//
// Reset contract: assert control_rst/cap_rst/rst together, release locally.
// Frame clear is NOT wired to these resets. A common cancellation must include
// AXI arbiter/slave; never locally reset an AXI master with a response in flight.
// Inputs enable/frame_meta must already be coherent in cap_clk at SOF. Control
// event_data comes from a HOLDING ready/valid producer, not raw FSM pulses.
module camera_evidence_client #(
    parameter integer SRC_WIDTH=1280,SRC_HEIGHT=720,SAMPLE_STRIDE=4,FRAME_INTERVAL=6,
    parameter integer PRE_FRAMES=20,POST_FRAMES=20,RING_FRAMES=64,
    parameter integer FIFO_DEPTH=256,EVENT_DEPTH=4,
    parameter [29:0] BASE_ADDR=30'h10000000,
    parameter integer SLOT_W=RING_FRAMES<2 ? 1 : $clog2(RING_FRAMES),
    parameter integer COUNT_W=$clog2(EVENT_DEPTH+1)
)(
    input wire clk,rst,control_clk,control_rst,cap_clk,cap_rst,
    input wire event_valid,
    input wire [255:0] event_data,
    output wire event_ready,
    output wire [31:0] cdc_accepted_count,cdc_delivered_count,
    input wire enable,de,sof,
    input wire [11:0] x,y,
    input wire [7:0] pixel_r,pixel_g,pixel_b,
    input wire [95:0] frame_meta,
    output wire [1:0] banks_occupied,
    output wire [31:0] frames_seen,frames_buffered,frames_sent,dropped_busy,dropped_invalid,dropped_disabled,
    output wire [COUNT_W-1:0] occupancy,high_water,
    output wire [31:0] accepted_count,rejected_count,completed_count,
    output wire out_valid,out_sof,out_last,
    output wire [15:0] out_data,
    output wire [95:0] out_meta,
    output wire [255:0] out_event,
    output wire out_deferred,
    input wire out_ready,
    output wire result_valid,result_ok,result_deferred,
    output wire [255:0] result_event,
    output wire [31:0] result_frames,
    input wire result_ready,
    output wire commit_valid,
    output wire [SLOT_W-1:0] commit_slot,
    output wire [95:0] commit_meta,
    output wire [31:0] frames_committed,frames_failed,windows_completed,read_errors,write_beats,read_beats,
    output wire [3:0] m_axi_awid,m_axi_arid,
    output wire [29:0] m_axi_awaddr,m_axi_araddr,
    output wire [7:0] m_axi_awlen,m_axi_arlen,
    output wire [2:0] m_axi_awsize,m_axi_arsize,
    output wire [1:0] m_axi_awburst,m_axi_arburst,
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
    wire ui_valid,ui_ready,pix_valid,pix_sof,pix_last,pix_ready;
    wire [255:0] ui_data;
    wire [15:0] pix_data;
    wire [95:0] pix_meta;
    // Conservative free-slot admission, independent of UI engine dispatch.
    // CDC keeps the payload while full; no repeating rejected pulse attempts.
    assign ui_ready=!rst && occupancy<EVENT_DEPTH;
    cdc_event_transaction event_bridge(
        .src_clk(control_clk),.src_rst(control_rst),.src_valid(event_valid),.src_data(event_data),.src_ready(event_ready),
        .src_accepted_count(cdc_accepted_count),.dst_clk(clk),.dst_rst(rst),.dst_valid(ui_valid),.dst_data(ui_data),
        .dst_ready(ui_ready),.dst_delivered_count(cdc_delivered_count));
    camera_sample_guard #(.SRC_WIDTH(SRC_WIDTH),.SRC_HEIGHT(SRC_HEIGHT),.SAMPLE_STRIDE(SAMPLE_STRIDE),.FRAME_INTERVAL(FRAME_INTERVAL)) sampler(
        .clk(cap_clk),.rst(cap_rst),.enable(enable),.pixel_r(pixel_r),.pixel_g(pixel_g),.pixel_b(pixel_b),
        .x(x),.y(y),.de(de),.sof(sof),.frame_meta(frame_meta),
        .out_valid(pix_valid),.out_sof(pix_sof),.out_last(pix_last),.out_data(pix_data),.out_meta(pix_meta),.out_ready(pix_ready),
        .banks_occupied(banks_occupied),.frames_seen(frames_seen),.frames_buffered(frames_buffered),.frames_sent(frames_sent),
        .dropped_busy(dropped_busy),.dropped_invalid(dropped_invalid),.dropped_disabled(dropped_disabled));
    ddr_evidence_queued #(.FRAME_PIXELS((SRC_WIDTH/SAMPLE_STRIDE)*(SRC_HEIGHT/SAMPLE_STRIDE)),
        .PRE_FRAMES(PRE_FRAMES),.POST_FRAMES(POST_FRAMES),.RING_FRAMES(RING_FRAMES),
        .FIFO_DEPTH(FIFO_DEPTH),.EVENT_DEPTH(EVENT_DEPTH),.BASE_ADDR(BASE_ADDR)) evidence(
        .clk(clk),.rst(rst),.cap_clk(cap_clk),.cap_rst(cap_rst),
        .pix_valid(pix_valid),.pix_sof(pix_sof),.pix_last(pix_last),.pix_data(pix_data),.pix_meta(pix_meta),.pix_ready(pix_ready),.fifo_full(),
        .request(ui_valid && ui_ready),.request_data(ui_data),.accepted(),.rejected(),
        .occupancy(occupancy),.high_water(high_water),.accepted_count(accepted_count),.rejected_count(rejected_count),.completed_count(completed_count),
        .out_valid(out_valid),.out_sof(out_sof),.out_last(out_last),.out_data(out_data),.out_meta(out_meta),
        .out_event(out_event),.out_deferred(out_deferred),.out_ready(out_ready),
        .result_valid(result_valid),.result_ok(result_ok),.result_deferred(result_deferred),.result_event(result_event),
        .result_frames(result_frames),.result_ready(result_ready),.commit_valid(commit_valid),.commit_slot(commit_slot),.commit_meta(commit_meta),
        .frames_committed(frames_committed),.frames_failed(frames_failed),.windows_completed(windows_completed),.read_errors(read_errors),
        .write_beats(write_beats),.read_beats(read_beats),
        .m_axi_awid(m_axi_awid),.m_axi_awaddr(m_axi_awaddr),.m_axi_awlen(m_axi_awlen),.m_axi_awsize(m_axi_awsize),.m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid),.m_axi_awready(m_axi_awready),.m_axi_wdata(m_axi_wdata),.m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),.m_axi_wvalid(m_axi_wvalid),.m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid),.m_axi_bresp(m_axi_bresp),.m_axi_bvalid(m_axi_bvalid),.m_axi_bready(m_axi_bready),
        .m_axi_arid(m_axi_arid),.m_axi_araddr(m_axi_araddr),.m_axi_arlen(m_axi_arlen),.m_axi_arsize(m_axi_arsize),.m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),.m_axi_arready(m_axi_arready),.m_axi_rid(m_axi_rid),.m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),.m_axi_rlast(m_axi_rlast),.m_axi_rvalid(m_axi_rvalid),.m_axi_rready(m_axi_rready));
endmodule
