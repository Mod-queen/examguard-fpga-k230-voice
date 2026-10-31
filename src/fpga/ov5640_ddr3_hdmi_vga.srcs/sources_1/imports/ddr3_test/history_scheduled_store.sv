`timescale 1ns/1ps
// Scheduled history data plane: one store (writer+directory+reader+one DMA)
// plus automatic closed-window scheduling and integrated point-gap journal.
// External source owns ordered frame/fence decisions and request/gap inputs.
// Whole subsystem, AXI slave and downstream consumers share cancellation reset.
module history_scheduled_store #(
    parameter integer FRAME_PIXELS=57600,SLOTS=64,WINDOWS=4,BURST=32,GAP_DEPTH=16,
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
    // event requests forwarded to the directory
    input wire request_valid,output wire request_ready,input wire [255:0] request_event,
    output wire accepted,output wire [WW-1:0] accepted_window,output wire [31:0] accepted_token,
    // ordered fence used for automatic sealing
    input wire fence_valid,input wire [63:0] fence_time,
    // point-gap records from the ordered ingress
    input wire gap_valid,output wire gap_ready,
    input wire [95:0] gap_meta,input wire [7:0] gap_reason,
    // automatically scheduled read output
    output wire out_valid,out_sof,out_last,output wire [15:0] out_data,
    output wire [95:0] out_meta,output wire [255:0] out_event,output wire [31:0] out_index,
    input wire out_ready,
    // merged result
    output wire result_valid,input wire result_ready,
    output wire [WW-1:0] result_window,output wire [31:0] result_token,
    output wire [2:0] result_code,
    output wire result_ok,result_truncated,result_capture_error,
    output wire [31:0] result_frames,
    output wire [31:0] result_gap_count,
    output wire result_gap_unknown,result_gap_bad_range,result_coverage_ok,
    output wire [63:0] result_lower,result_upper,
    output wire [95:0] result_gap_first_meta,result_gap_last_meta,
    output wire [7:0] result_gap_first_reason,result_gap_last_reason,
    output wire [255:0] result_event,
    output wire scheduler_halted,scheduler_protocol_fault,
    output wire [WW:0] pending_windows,
    output wire [63:0] sealed_time,
    output wire [31:0] gap_recorded,gap_evicted,
    output wire journal_halted,
    // pass-through store status
    output wire [SLOTS-1:0] protected_slots,
    output wire [2:0] faults,
    output wire token_exhausted,window_token_exhausted,
    output wire [31:0] frames_committed,frames_dropped,reserve_rejected,write_failed,write_beats,read_beats,
    output wire done,done_ok,
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
    wire store_request_ready,sched_request_ready;
    wire store_accepted;
    wire [WW-1:0] store_accepted_window;
    wire [31:0] store_accepted_token;
    wire store_seal_valid,store_seal_ready;
    wire [63:0] store_seal_time;
    wire directory_writer_pending;
    wire [WINDOWS-1:0] directory_active_mask,directory_closed_mask;
    wire store_read_valid,store_read_ready;
    wire [WW-1:0] store_read_window;
    wire [31:0] store_read_token;
    wire sr_valid,sr_ok,sr_truncated,sr_capture_error;
    wire [2:0] sr_code;
    wire [31:0] sr_frames,sr_token;
    wire [WW-1:0] sr_window;
    wire store_result_ready;
    assign request_ready=store_request_ready && sched_request_ready;
    history_store_axi #(.FRAME_PIXELS(FRAME_PIXELS),.SLOTS(SLOTS),.WINDOWS(WINDOWS),.BURST(BURST),
        .PRE_MS(PRE_MS),.POST_MS(POST_MS),.BASE_ADDR(BASE_ADDR)) store(
        .clk(clk),.rst(rst),
        .frame_valid(frame_valid),.frame_ready(frame_ready),.frame_fence(frame_fence),.frame_meta(frame_meta),
        .pixel_valid(pixel_valid),.pixel_last(pixel_last),.pixel_data(pixel_data),.pixel_ready(pixel_ready),
        .write_result_valid(write_result_valid),.write_result_ready(write_result_ready),
        .write_result_meta(write_result_meta),.write_result_code(write_result_code),
        .fence_done(fence_done),.fence_ok(fence_ok),
        .request_valid(request_valid && sched_request_ready),.request_ready(store_request_ready),.request_event(request_event),
        .accepted(store_accepted),.accepted_window(store_accepted_window),.accepted_token(store_accepted_token),
        .dir_seal_valid(store_seal_valid),.dir_seal_ready(store_seal_ready),.dir_seal_time(store_seal_time),
        .directory_writer_pending(directory_writer_pending),
        .directory_active_mask(directory_active_mask),.directory_closed_mask(directory_closed_mask),
        .read_valid(store_read_valid),.read_ready(store_read_ready),
        .read_window(store_read_window),.read_token(store_read_token),
        .out_valid(out_valid),.out_sof(out_sof),.out_last(out_last),.out_data(out_data),
        .out_meta(out_meta),.out_event(out_event),.out_index(out_index),.out_ready(out_ready),
        .result_valid(sr_valid),.result_ready(store_result_ready),.result_code(sr_code),
        .result_ok(sr_ok),.result_truncated(sr_truncated),.result_capture_error(sr_capture_error),
        .result_frames(sr_frames),.result_token(sr_token),.result_window(sr_window),
        .done(done),.done_ok(done_ok),.protected_slots(protected_slots),.faults(faults),
        .token_exhausted(token_exhausted),.window_token_exhausted(window_token_exhausted),
        .frames_committed(frames_committed),.frames_dropped(frames_dropped),.reserve_rejected(reserve_rejected),
        .write_failed(write_failed),.write_beats(write_beats),.read_beats(read_beats),
        .m_axi_awid(m_axi_awid),.m_axi_arid(m_axi_arid),.m_axi_awaddr(m_axi_awaddr),.m_axi_araddr(m_axi_araddr),
        .m_axi_awlen(m_axi_awlen),.m_axi_arlen(m_axi_arlen),.m_axi_awsize(m_axi_awsize),.m_axi_arsize(m_axi_arsize),
        .m_axi_awburst(m_axi_awburst),.m_axi_arburst(m_axi_arburst),.m_axi_awvalid(m_axi_awvalid),.m_axi_arvalid(m_axi_arvalid),
        .m_axi_awready(m_axi_awready),.m_axi_arready(m_axi_arready),
        .m_axi_wdata(m_axi_wdata),.m_axi_wstrb(m_axi_wstrb),.m_axi_wlast(m_axi_wlast),.m_axi_wvalid(m_axi_wvalid),.m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid),.m_axi_rid(m_axi_rid),.m_axi_bresp(m_axi_bresp),.m_axi_rresp(m_axi_rresp),
        .m_axi_bvalid(m_axi_bvalid),.m_axi_rvalid(m_axi_rvalid),.m_axi_rlast(m_axi_rlast),.m_axi_rdata(m_axi_rdata),
        .m_axi_bready(m_axi_bready),.m_axi_rready(m_axi_rready));
    // The scheduler owns read commands, sealing, gap merge and the presented
    // result. The store's result pins are consumed internally.
    history_closed_scheduler #(.WINDOWS(WINDOWS),.GAP_DEPTH(GAP_DEPTH),
        .PRE_MS(PRE_MS),.POST_MS(POST_MS)) scheduler(
        .clk(clk),.rst(rst),
        .request_ready(sched_request_ready),.request_event(request_event),
        .accepted(store_accepted),.accepted_window(store_accepted_window),.accepted_token(store_accepted_token),
        .fence_valid(fence_valid),.fence_time(fence_time),
        .directory_writer_pending(directory_writer_pending),
        .directory_closed_mask(directory_closed_mask),
        .seal_valid(store_seal_valid),.seal_ready(store_seal_ready),.seal_time(store_seal_time),
        .read_valid(store_read_valid),.read_ready(store_read_ready),
        .read_window(store_read_window),.read_token(store_read_token),
        .s_result_valid(sr_valid),.s_result_ready(store_result_ready),.s_result_code(sr_code),
        .s_result_ok(sr_ok),.s_result_truncated(sr_truncated),.s_result_capture_error(sr_capture_error),
        .s_result_frames(sr_frames),.s_result_token(sr_token),.s_result_window(sr_window),
        .gap_valid(gap_valid),.gap_ready(gap_ready),.gap_meta(gap_meta),.gap_reason(gap_reason),
        .result_valid(result_valid),.result_ready(result_ready),
        .result_window(result_window),.result_token(result_token),.result_code(result_code),
        .result_ok(result_ok),.result_truncated(result_truncated),.result_capture_error(result_capture_error),
        .result_frames(result_frames),.result_gap_count(result_gap_count),
        .result_gap_unknown(result_gap_unknown),.result_gap_bad_range(result_gap_bad_range),
        .result_coverage_ok(result_coverage_ok),.result_lower(result_lower),.result_upper(result_upper),
        .result_gap_first_meta(result_gap_first_meta),.result_gap_last_meta(result_gap_last_meta),
        .result_gap_first_reason(result_gap_first_reason),.result_gap_last_reason(result_gap_last_reason),
        .result_event(result_event),.store_faults(faults),
        .halted(scheduler_halted),.protocol_fault(scheduler_protocol_fault),
        .pending_windows(pending_windows),.sealed_time(sealed_time),
        .gap_recorded_count(gap_recorded),.gap_evicted_count(gap_evicted),.journal_halted_o(journal_halted));
    assign accepted=store_accepted;
    assign accepted_window=store_accepted_window;
    assign accepted_token=store_accepted_token;
    // synthesis translate_off
    initial if(FRAME_PIXELS<1 || SLOTS<1 || WINDOWS<1 || GAP_DEPTH<1 || BASE_ADDR[3:0]!=0)
        $fatal(1,"FAIL: history scheduled store parameters");
    // synthesis translate_on
endmodule
