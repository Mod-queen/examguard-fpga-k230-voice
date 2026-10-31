`timescale 1ns/1ps
// Independent single-clock history data plane, ONE DMA, no MIG/CDC/packetizer.
// External source owns ordered frame/fence commands; external event scheduler
// owns request and read commands. Accepted handles must be queued by caller.
// Whole subsystem, AXI slave and downstream consumers share cancellation reset.
module history_store_axi #(
    parameter integer FRAME_PIXELS=57600,SLOTS=64,WINDOWS=4,BURST=32,
    parameter integer SW=SLOTS<2?1:$clog2(SLOTS),WW=WINDOWS<2?1:$clog2(WINDOWS),
    parameter [63:0] PRE_MS=2000,POST_MS=2000,
    parameter [29:0] BASE_ADDR=30'h10000000
)(
    input wire clk,rst,
    input wire frame_valid,output wire frame_ready,
    input wire frame_fence,input wire [95:0] frame_meta,
    input wire pixel_valid,pixel_last,input wire [15:0] pixel_data,output wire pixel_ready,
    output wire write_result_valid,input wire write_result_ready,
    output wire [95:0] write_result_meta,output wire [2:0] write_result_code,
    output wire fence_done,fence_ok,
    input wire request_valid,output wire request_ready,input wire [255:0] request_event,
    output wire accepted,output wire [WW-1:0] accepted_window,output wire [31:0] accepted_token,
    // External scheduler seal (the writer still owns its own frame/fence stream).
    // Do NOT drive both external seal and a fence command for the same frontier.
    input wire dir_seal_valid,output wire dir_seal_ready,input wire [63:0] dir_seal_time,
    output wire directory_writer_pending,
    output wire [WINDOWS-1:0] directory_active_mask,directory_closed_mask,
    input wire read_valid,output wire read_ready,
    input wire [WW-1:0] read_window,input wire [31:0] read_token,
    output wire out_valid,out_sof,out_last,output wire [15:0] out_data,
    output wire [95:0] out_meta,output wire [255:0] out_event,output wire [31:0] out_index,
    input wire out_ready,
    output wire result_valid,input wire result_ready,
    output wire [2:0] result_code,output wire result_ok,result_truncated,result_capture_error,
    output wire [31:0] result_frames,result_token,output wire [WW-1:0] result_window,
    output wire done,done_ok,
    output wire [SLOTS-1:0] protected_slots,
    output wire [2:0] faults, // writer/reader/directory sticky, bit2/1/0
    output wire token_exhausted,window_token_exhausted,
    output wire [31:0] frames_committed,frames_dropped,reserve_rejected,write_failed,write_beats,read_beats,
    output wire [3:0] m_axi_awid,m_axi_arid,
    output wire [29:0] m_axi_awaddr,m_axi_araddr,
    output wire [7:0] m_axi_awlen,m_axi_arlen,
    output wire [2:0] m_axi_awsize,m_axi_arsize,
    output wire [1:0] m_axi_awburst,m_axi_arburst,
    output wire m_axi_awvalid,m_axi_arvalid,
    input wire m_axi_awready,m_axi_arready,
    output wire [127:0] m_axi_wdata,output wire [15:0] m_axi_wstrb,
    output wire m_axi_wlast,m_axi_wvalid,input wire m_axi_wready,
    input wire [3:0] m_axi_bid,m_axi_rid,
    input wire [1:0] m_axi_bresp,m_axi_rresp,
    input wire m_axi_bvalid,m_axi_rvalid,m_axi_rlast,
    input wire [127:0] m_axi_rdata,output wire m_axi_bready,m_axi_rready
);
    wire reserve_valid,reserve_ready,grant_valid,grant_ready,grant_ok;
    wire [SW-1:0] grant_slot,finish_slot,query_slot;
    wire [31:0] grant_token,finish_token,query_token,release_token;
    wire finish_valid,finish_ready,finish_ok;
    wire [95:0] finish_meta,slot_meta;
    wire release_valid,release_ready,release_done,release_ok;
    wire seal_valid,seal_ready;
    wire [63:0] seal_time;
    wire seal_mux_valid=seal_valid || dir_seal_valid;
    wire [63:0] seal_mux_time=dir_seal_valid ? dir_seal_time : seal_time;
    wire seal_mux_ready;
    assign seal_ready=seal_mux_ready;
    assign dir_seal_ready=seal_mux_ready;
    wire [WW-1:0] release_window,query_window;
    wire query_active,query_closed,query_truncated,query_capture_error,slot_valid;
    wire [SLOTS-1:0] query_slots;
    wire [255:0] query_event;
    // A full window table may leave a source request held indefinitely. Do not
    // present that blocked request to the directory priority arbiter: otherwise
    // it can starve frame reserve and the ordered fence behind that frame.
    // Directory request_ready does not depend on request_valid or reserve_valid.
    history_reference_directory #(.SLOTS(SLOTS),.WINDOWS(WINDOWS),.ENABLE_WINDOW_TOKENS(1),
        .PRE_MS(PRE_MS),.POST_MS(POST_MS)) directory(
        .request_valid(request_valid && request_ready),.protocol_fault(faults[0]),
        .writer_pending_o(directory_writer_pending),.active_mask(directory_active_mask),
        .closed_mask(directory_closed_mask),
        .seal_valid(seal_mux_valid),.seal_ready(seal_mux_ready),.seal_time(seal_mux_time),.*);
    wire wr_start,wr_busy,wr_done,wr_ok,rd_start,rd_busy,rd_done,rd_ok;
    wire [29:0] wr_base,rd_base;
    wire write_valid,write_last,write_ready;
    wire [15:0] write_data;
    wire dma_valid,dma_sof,dma_last,dma_ready;
    wire [15:0] dma_data;
    history_frame_writer #(.FRAME_PIXELS(FRAME_PIXELS),.SLOTS(SLOTS),.BASE_ADDR(BASE_ADDR)) writer(
        .command_valid(frame_valid),.command_ready(frame_ready),.command_fence(frame_fence),.command_meta(frame_meta),
        .dma_valid(write_valid),.dma_last(write_last),.dma_data(write_data),.dma_ready(write_ready),
        .result_valid(write_result_valid),.result_ready(write_result_ready),.result_meta(write_result_meta),
        .result_code(write_result_code),.protocol_fault(faults[2]),.*);
    history_window_reader #(.FRAME_PIXELS(FRAME_PIXELS),.SLOTS(SLOTS),.WINDOWS(WINDOWS),.BASE_ADDR(BASE_ADDR)) reader(
        .command_valid(read_valid),.command_ready(read_ready),.command_window(read_window),.command_token(read_token),
        .protocol_fault(faults[1]),.*);
    ddr3_axi_frame_dma #(.FRAME_PIXELS(FRAME_PIXELS),.BURST(BURST)) dma(
        .in_valid(write_valid),.in_last(write_last),.in_data(write_data),.in_ready(write_ready),
        .out_valid(dma_valid),.out_sof(dma_sof),.out_last(dma_last),.out_data(dma_data),.out_ready(dma_ready),.*);
endmodule
