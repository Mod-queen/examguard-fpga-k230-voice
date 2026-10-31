`timescale 1ns/1ps
// Integration-ready evidence CLIENT, no MIG/video/PHY here. Four domain resets
// must be outputs of one common cancellation barrier shared with AXI slave and
// arbiter. clk is UI; control_clk is FSM; cap_clk is pre-overlay display stream;
// eth_clk is125MHz. A UDP packet is buffered in eth_clk before its start pulse.
module camera_evidence_transport #(
    parameter integer SRC_WIDTH=1280,SRC_HEIGHT=720,SAMPLE_STRIDE=4,FRAME_INTERVAL=6,
    parameter integer PRE_FRAMES=20,POST_FRAMES=20,RING_FRAMES=64,
    parameter integer FIFO_DEPTH=256,EVENT_DEPTH=4,PACKET_FIFO_DEPTH=256,CHUNK_PIXELS=512,
    parameter [29:0] BASE_ADDR=30'h10000000,
    parameter [31:0] MAX_AGE_CYCLES=74250,
    parameter integer REQUIRE_TX_QUALIFIED=0
)(
    input wire clk,rst,control_clk,control_rst,cap_clk,cap_rst,eth_clk,eth_rst,
    input wire tx_qualified, // eth_clk domain; link failures do NOT reset AXI
    input wire [63:0] control_time_ms,
    input wire event_valid,
    input wire [255:0] event_data,
    output wire event_ready,
    input wire enable,de,sof,
    input wire [11:0] x,y,
    input wire [7:0] pixel_r,pixel_g,pixel_b,
    input wire [31:0] frame_id,
    output wire [31:0] rejected_unknown,rejected_stale,
    output wire [31:0] frames_committed,frames_failed,read_errors,
    output wire [31:0] packets_sent,results_sent,udp_packets_sent,udp_packets_dropped,
    output wire packet_fault,udp_fault,
    output wire [255:0] cap_health_stats,ui_health_stats,
    output wire [127:0] eth_health_stats,
    output wire tx_en_pulse,
    output wire [15:0] data_length,
    output wire [7:0] payload_data,
    input wire payload_req,tx_done,
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
    wire [63:0] time_ms;
    wire time_valid,frame_enable;
    wire [31:0] age_cycles;
    wire [95:0] frame_meta;
    cdc_time_snapshot time_bridge(.src_clk(control_clk),.src_rst(control_rst),.src_time_ms(control_time_ms),
        .dst_clk(cap_clk),.dst_rst(cap_rst),.time_ms(time_ms),.time_valid(time_valid),.age_cycles(age_cycles));
    camera_time_guard #(.MAX_AGE_CYCLES(MAX_AGE_CYCLES)) time_guard(.clk(cap_clk),.rst(cap_rst),.sof(sof),.enable(enable),
        .frame_id(frame_id),.time_ms(time_ms),.time_valid(time_valid),.age_cycles(age_cycles),
        .frame_enable(frame_enable),.frame_meta(frame_meta),.rejected_unknown(rejected_unknown),.rejected_stale(rejected_stale));
    wire out_valid,out_sof,out_last,out_deferred,out_ready,result_valid,result_ok,result_deferred,result_ready;
    wire [15:0] out_data;
    wire [95:0] out_meta;
    wire [255:0] out_event,result_event;
    wire [31:0] result_frames;
    wire eth_valid,eth_last,eth_ready;
    wire [31:0] seen,buffered,sent,drop_busy,drop_invalid,drop_disabled;
    wire [$clog2(EVENT_DEPTH+1)-1:0] ui_occupancy,ui_high_water;
    wire [31:0] ui_accepted,ui_completed;
    wire [7:0] ui_occupancy_byte=ui_occupancy,ui_high_water_byte=ui_high_water;
    wire [31:0] failed_windows;
    reg [31:0] failed_window_count;
    assign failed_windows=failed_window_count;
    always @(posedge clk) begin
        if(rst) failed_window_count<=0;
        else if(result_valid && result_ready && !result_ok && failed_window_count!=32'hffffffff) failed_window_count<=failed_window_count+1'b1;
    end
    assign cap_health_stats={seen,buffered,sent,drop_busy,drop_invalid,drop_disabled,rejected_unknown,rejected_stale};
    assign ui_health_stats={ (ui_accepted!=ui_completed || out_valid || result_valid || ui_occupancy!=0),packet_fault,14'd0,ui_high_water_byte,ui_occupancy_byte,
        ui_accepted,ui_completed,frames_committed,frames_failed,read_errors,failed_windows,packets_sent};
    // bit0 backpressure is live per snapshot; bit1 fault sticky for this epoch.
    assign eth_health_stats={30'd0,udp_fault,(eth_valid && !eth_ready),udp_packets_sent,udp_packets_dropped,32'd0};
    camera_evidence_client #(.SRC_WIDTH(SRC_WIDTH),.SRC_HEIGHT(SRC_HEIGHT),.SAMPLE_STRIDE(SAMPLE_STRIDE),.FRAME_INTERVAL(FRAME_INTERVAL),
        .PRE_FRAMES(PRE_FRAMES),.POST_FRAMES(POST_FRAMES),.RING_FRAMES(RING_FRAMES),.FIFO_DEPTH(FIFO_DEPTH),.EVENT_DEPTH(EVENT_DEPTH),.BASE_ADDR(BASE_ADDR)) client(
        .clk(clk),.rst(rst),.control_clk(control_clk),.control_rst(control_rst),.cap_clk(cap_clk),.cap_rst(cap_rst),
        .event_valid(event_valid),.event_data(event_data),.event_ready(event_ready),.cdc_accepted_count(),.cdc_delivered_count(),
        .enable(frame_enable),.de(de),.sof(sof),.x(x),.y(y),.pixel_r(pixel_r),.pixel_g(pixel_g),.pixel_b(pixel_b),.frame_meta(frame_meta),
        .banks_occupied(),.frames_seen(seen),.frames_buffered(buffered),.frames_sent(sent),.dropped_busy(drop_busy),.dropped_invalid(drop_invalid),.dropped_disabled(drop_disabled),
        .occupancy(ui_occupancy),.high_water(ui_high_water),.accepted_count(ui_accepted),.rejected_count(),.completed_count(ui_completed),
        .out_valid(out_valid),.out_sof(out_sof),.out_last(out_last),.out_data(out_data),.out_meta(out_meta),.out_event(out_event),.out_deferred(out_deferred),.out_ready(out_ready),
        .result_valid(result_valid),.result_ok(result_ok),.result_deferred(result_deferred),.result_event(result_event),.result_frames(result_frames),.result_ready(result_ready),
        .commit_valid(),.commit_slot(),.commit_meta(),.frames_committed(frames_committed),.frames_failed(frames_failed),.windows_completed(),.read_errors(read_errors),.write_beats(),.read_beats(),
        .m_axi_awid(m_axi_awid),.m_axi_awaddr(m_axi_awaddr),.m_axi_awlen(m_axi_awlen),.m_axi_awsize(m_axi_awsize),.m_axi_awburst(m_axi_awburst),.m_axi_awvalid(m_axi_awvalid),.m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),.m_axi_wstrb(m_axi_wstrb),.m_axi_wlast(m_axi_wlast),.m_axi_wvalid(m_axi_wvalid),.m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid),.m_axi_bresp(m_axi_bresp),.m_axi_bvalid(m_axi_bvalid),.m_axi_bready(m_axi_bready),
        .m_axi_arid(m_axi_arid),.m_axi_araddr(m_axi_araddr),.m_axi_arlen(m_axi_arlen),.m_axi_arsize(m_axi_arsize),.m_axi_arburst(m_axi_arburst),.m_axi_arvalid(m_axi_arvalid),.m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid),.m_axi_rdata(m_axi_rdata),.m_axi_rresp(m_axi_rresp),.m_axi_rlast(m_axi_rlast),.m_axi_rvalid(m_axi_rvalid),.m_axi_rready(m_axi_rready));
    wire tx_valid,tx_last,tx_ready;
    wire [7:0] tx_data;
    evidence_window_packetizer #(.WIDTH(SRC_WIDTH/SAMPLE_STRIDE),.HEIGHT(SRC_HEIGHT/SAMPLE_STRIDE),.CHUNK_PIXELS(CHUNK_PIXELS)) packetizer(
        .clk(clk),.rst(rst),.out_valid(out_valid),.out_sof(out_sof),.out_last(out_last),.out_data(out_data),.out_meta(out_meta),.out_event(out_event),.out_deferred(out_deferred),.out_ready(out_ready),
        .result_valid(result_valid),.result_ok(result_ok),.result_deferred(result_deferred),.result_event(result_event),.result_frames(result_frames),.result_ready(result_ready),
        .tx_valid(tx_valid),.tx_last(tx_last),.tx_data(tx_data),.tx_ready(tx_ready),.protocol_fault(packet_fault),.packets_sent(packets_sent),.results_sent(results_sent));
    wire [7:0] eth_data;
    evidence_packet_cdc #(.DEPTH(PACKET_FIFO_DEPTH)) packet_cdc(.src_clk(clk),.src_rst(rst),.src_valid(tx_valid),.src_last(tx_last),.src_data(tx_data),.src_ready(tx_ready),
        .dst_clk(eth_clk),.dst_rst(eth_rst),.dst_valid(eth_valid),.dst_last(eth_last),.dst_data(eth_data),.dst_ready(eth_ready));
    evidence_packet_udp_bridge #(.REQUIRE_TX_QUALIFIED(REQUIRE_TX_QUALIFIED)) udp_bridge(
        .clk(eth_clk),.rst(eth_rst),.tx_qualified(tx_qualified),.in_valid(eth_valid),.in_last(eth_last),.in_data(eth_data),.in_ready(eth_ready),
        .tx_en_pulse(tx_en_pulse),.data_length(data_length),.payload_req(payload_req),.payload_data(payload_data),.tx_done(tx_done),
        .protocol_fault(udp_fault),.packets_sent(udp_packets_sent),.packets_dropped(udp_packets_dropped));
endmodule
