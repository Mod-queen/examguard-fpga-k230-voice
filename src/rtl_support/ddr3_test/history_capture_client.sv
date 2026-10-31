`timescale 1ns/1ps
// Coherent time + sampling/command CDC + epoch cancellation + ordered ingress
// + automatic closed-window history store. The capture clock is independent;
// the UI/identity domain and control domain are separate. Pixel windows are
// selected from the PRE-OVERLAY display RGB tap, not raw DVP bytes.
// Ordered ingress fences are sent to the writer, which seals the directory;
// the scheduler's separate external seal input is intentionally tied off here
// to avoid a second seal source. All domains/AXI users must share cancellation.
module history_capture_client #(
    parameter integer SRC_WIDTH=1280,SRC_HEIGHT=720,SAMPLE_STRIDE=4,FRAME_INTERVAL=6,
    parameter integer CAP_DEPTH=16,CDC_DEPTH=64,
    parameter integer SLOTS=64,WINDOWS=4,BURST=32,GAP_DEPTH=16,
    parameter [63:0] PRE_MS=2000,POST_MS=2000,
    parameter [31:0] MAX_AGE_CYCLES=74250,
    parameter [29:0] BASE_ADDR=30'h10000000,
    parameter integer WITH_HR_UDP=0,
    parameter integer EXTERNAL_CAP_TIME=0,
    parameter integer WITH_EXTERNAL_HALT=0,
    parameter integer SW=SLOTS<2?1:$clog2(SLOTS),WW=WINDOWS<2?1:$clog2(WINDOWS)
)(
    input wire clk,                 // UI / identity domain
    input wire control_clk,         // cancellation barrier domain
    input wire cap_clk,             // display sampling domain
    input wire system_rst,          // asynchronous, resets identity and all users
    input wire transport_rst,       // cancels transport epoch but preserves identity
    input wire restart,             // control-domain pulse after halt, no old handles
    input wire ms_tick,session_start,session_end,
    input wire [31:0] device_straps,
    output wire [31:0] device_id,boot_id,session_id,
    output wire [63:0] time_ms,
    output wire session_active,boot_exhausted,identity_request_enable,
    // PRE-OVERLAY display tap
    input wire cap_enable,
    input wire [7:0] pixel_r,pixel_g,pixel_b,
    input wire [11:0] x,y,
    input wire de,sof,
    input wire [63:0] cap_time_ms,
    input wire cap_time_valid,
    input wire [31:0] cap_time_age,
    input wire external_ui_halt,
    // original-event window request (already carries full 256-bit identity)
    input wire event_valid,output wire event_ready,input wire [255:0] event_event,
    // per-decision receipt from ordered ingress
    output wire decision_valid,input wire decision_ready,
    output wire [1:0] decision_kind,output wire [95:0] decision_meta,output wire [2:0] decision_code,
    // automatically scheduled read/result
    output wire out_valid,out_sof,out_last,output wire [15:0] out_data,
    output wire [95:0] out_meta,output wire [255:0] out_event,output wire [31:0] out_index,
    input wire out_ready,
    output wire result_valid,input wire result_ready,
    output wire [WW-1:0] result_window,output wire [31:0] result_token,
    output wire [2:0] result_code,
    output wire result_ok,result_truncated,result_capture_error,
    output wire [31:0] result_frames,result_gap_count,
    output wire result_gap_unknown,result_gap_bad_range,result_coverage_ok,
    output wire [63:0] result_lower,result_upper,
    output wire [95:0] result_gap_first_meta,result_gap_last_meta,
    output wire [7:0] result_gap_first_reason,result_gap_last_reason,
    output wire [255:0] result_event,
    // optional same-clock HR result datagram path
    input wire hr_tx_qualified,
    output wire hr_tx_en_pulse,output wire [15:0] hr_data_length,
    input wire hr_payload_req,hr_tx_done,output wire [7:0] hr_payload_data,
    output wire hr_protocol_fault,
    output wire [31:0] hr_records_sent,hr_packets_sent,hr_packets_dropped,
    // lifecycle/status
    output wire ui_rst,cap_rst,control_rst,cancelled,
    output wire [31:0] cancellation_count,
    output wire src_halted,dst_halted,source_halted,cdc_src_halted,cdc_dst_halted,
    output wire ingress_halted,journal_halted,client_halted,
    output wire [31:0] source_sofs,cadence_skipped,time_unknown_count,time_stale_count,
    output wire [31:0] frames_seen,frames_published,capture_dropped,decisions_sent,
    output wire [31:0] decisions_completed,gaps_recorded,gap_recorded,gap_evicted,
    output wire [WW:0] pending_windows,
    output wire [31:0] frames_committed,frames_dropped,reserve_rejected,write_failed,
    output wire [2:0] faults,output wire [SLOTS-1:0] protected_slots,
    output wire done,done_ok,
    // AXI4 master (one DMA); external slave shares ui_rst/system cancellation
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
    localparam integer FP=(SRC_WIDTH/SAMPLE_STRIDE)*(SRC_HEIGHT/SAMPLE_STRIDE);
    wire [63:0] identity_time;
    evidence_epoch_identity identity(
        .clk(clk),.system_rst(system_rst),.transport_rst(transport_rst),.ms_tick(ms_tick),
        .session_start(session_start),.session_end(session_end),.device_straps(device_straps),
        .device_id(device_id),.boot_id(boot_id),.session_id(session_id),.time_ms(identity_time),
        .session_active(session_active),.request_rst(),
        .request_enable(identity_request_enable),.boot_exhausted(boot_exhausted));
    assign time_ms=identity_time;
    wire source_halted_i,cdc_src_halted_i,cdc_dst_halted_i;
    wire ingress_halted_i,journal_halted_i;
    wire stream_cancelled;
    reg dst_halt_registered;
    always @(posedge clk) begin
        if(ui_rst) dst_halt_registered<=0;
        else dst_halt_registered<=ingress_halted_i || journal_halted_i || cdc_dst_halted_i || client_halted || |faults ||
            (WITH_EXTERNAL_HALT && external_ui_halt);
    end
    history_stream_epoch epoch(.control_clk(control_clk),.src_clk(cap_clk),.dst_clk(clk),
        .arst(system_rst || transport_rst),.restart(restart),
        .src_halt(source_halted_i || cdc_src_halted_i),
        .dst_halt(dst_halt_registered),
        .control_rst(control_rst),.src_rst(cap_rst),.dst_rst(ui_rst),
        .cancelled(stream_cancelled),.cancellation_count(cancellation_count));
    assign cancelled=stream_cancelled;
    // Identity time is a coherent recent snapshot in the sampling domain.
    wire [63:0] sample_time_ms;
    wire sample_time_valid;
    wire [31:0] sample_age_cycles;
    cdc_time_snapshot time_snapshot(.src_clk(clk),.src_rst(ui_rst),.src_time_ms(identity_time),
        .dst_clk(cap_clk),.dst_rst(cap_rst),.time_ms(sample_time_ms),
        .time_valid(sample_time_valid),.age_cycles(sample_age_cycles));
    wire [63:0] capture_time=EXTERNAL_CAP_TIME ? cap_time_ms : sample_time_ms;
    wire capture_time_valid=EXTERNAL_CAP_TIME ? cap_time_valid : sample_time_valid;
    wire [31:0] capture_age=EXTERNAL_CAP_TIME ? cap_time_age : sample_age_cycles;
    wire sample_open;
    history_startup_gate #(.MAX_AGE_CYCLES(MAX_AGE_CYCLES)) startup(
        .clk(cap_clk),.rst(cap_rst),.sof(sof),.time_valid(capture_time_valid),.age_cycles(capture_age),
        .sample_open(sample_open),.armed());
    reg [31:0] source_frame_id;
    always @(posedge cap_clk) begin
        if(cap_rst) source_frame_id<=0;
        else if(sof) source_frame_id<=source_frame_id+1'b1;
    end
    wire cap_command_valid,cap_command_ready,cap_pixel_valid,cap_pixel_last,cap_pixel_ready;
    wire [1:0] cap_command_kind;
    wire [95:0] cap_command_meta;
    wire [7:0] cap_command_reason;
    wire [15:0] cap_pixel_data;
    wire [2:0] source_halt_reason;
    wire [$clog2(CAP_DEPTH+1)-1:0] source_occupancy;
    wire [1:0] source_banks_occupied;
    history_sample_source #(.SRC_WIDTH(SRC_WIDTH),.SRC_HEIGHT(SRC_HEIGHT),
        .SAMPLE_STRIDE(SAMPLE_STRIDE),.FRAME_INTERVAL(FRAME_INTERVAL),.DEPTH(CAP_DEPTH),
        .MAX_AGE_CYCLES(MAX_AGE_CYCLES)) sampler(
        .clk(cap_clk),.rst(cap_rst),.enable(cap_enable),
        .pixel_r(pixel_r),.pixel_g(pixel_g),.pixel_b(pixel_b),.x(x),.y(y),.de(de && sample_open),.sof(sof && sample_open),
        .frame_id(source_frame_id),.time_ms(capture_time),.time_valid(capture_time_valid),
        .age_cycles(capture_age),
        .command_valid(cap_command_valid),.command_ready(cap_command_ready),
        .command_kind(cap_command_kind),.command_meta(cap_command_meta),.command_reason(cap_command_reason),
        .pixel_valid(cap_pixel_valid),.pixel_last(cap_pixel_last),.pixel_data(cap_pixel_data),.pixel_ready(cap_pixel_ready),
        .halted(source_halted_i),.halt_reason(source_halt_reason),.occupancy(source_occupancy),
        .banks_occupied(source_banks_occupied),.frames_seen(frames_seen),.frames_published(frames_published),
        .frames_dropped(capture_dropped),.decisions_sent(decisions_sent),
        .source_sofs(source_sofs),.cadence_skipped(cadence_skipped),
        .time_unknown(time_unknown_count),.time_stale(time_stale_count));
    assign source_halted=source_halted_i;
    wire command_valid,command_ready,source_valid,source_last,source_ready;
    wire [1:0] command_kind;
    wire [95:0] command_meta;
    wire [7:0] command_reason;
    wire [15:0] source_data;
    history_stream_cdc #(.DEPTH(CDC_DEPTH)) bridge(
        .src_clk(cap_clk),.src_rst(cap_rst),.dst_clk(clk),.dst_rst(ui_rst),
        .command_valid(cap_command_valid),.command_ready(cap_command_ready),
        .command_kind(cap_command_kind),.command_meta(cap_command_meta),.command_reason(cap_command_reason),
        .pixel_valid(cap_pixel_valid),.pixel_last(cap_pixel_last),.pixel_data(cap_pixel_data),.pixel_ready(cap_pixel_ready),
        .dst_command_valid(command_valid),.dst_command_ready(command_ready),.dst_command_kind(command_kind),
        .dst_command_meta(command_meta),.dst_command_reason(command_reason),
        .dst_pixel_valid(source_valid),.dst_pixel_last(source_last),.dst_pixel_data(source_data),
        .dst_pixel_ready(source_ready),.src_halted(cdc_src_halted_i),.dst_halted(cdc_dst_halted_i));
    assign cdc_src_halted=cdc_src_halted_i;
    assign cdc_dst_halted=cdc_dst_halted_i;
    assign src_halted=source_halted_i || cdc_src_halted_i;
    assign dst_halted=ingress_halted_i || journal_halted_i || cdc_dst_halted_i;
    wire frame_valid,frame_ready,frame_fence,pixel_valid,pixel_last,pixel_ready;
    wire [95:0] frame_meta,write_result_meta;
    wire [15:0] pixel_data;
    wire write_result_valid,write_result_ready,fence_done,fence_ok,gap_valid,gap_ready;
    wire [2:0] write_result_code;
    wire [95:0] gap_meta;
    wire [7:0] gap_reason;
    history_ordered_ingress ingress(.clk(clk),.rst(ui_rst),
        .command_valid(command_valid),.command_ready(command_ready),
        .command_kind(command_kind),.command_meta(command_meta),.command_reason(command_reason),
        .source_valid(source_valid),.source_last(source_last),.source_data(source_data),.source_ready(source_ready),
        .frame_valid(frame_valid),.frame_ready(frame_ready),.frame_fence(frame_fence),.frame_meta(frame_meta),
        .pixel_valid(pixel_valid),.pixel_last(pixel_last),.pixel_data(pixel_data),.pixel_ready(pixel_ready),
        .write_result_valid(write_result_valid),.write_result_ready(write_result_ready),
        .write_result_meta(write_result_meta),.write_result_code(write_result_code),
        .fence_done(fence_done),.fence_ok(fence_ok),
        .gap_valid(gap_valid),.gap_ready(gap_ready),.gap_meta(gap_meta),.gap_reason(gap_reason),
        .result_valid(decision_valid),.result_ready(decision_ready),.result_kind(decision_kind),
        .result_meta(decision_meta),.result_code(decision_code),
        .halted(ingress_halted_i),.decisions_completed(decisions_completed),.gaps_recorded(gaps_recorded));
    assign ingress_halted=ingress_halted_i;
    wire store_request_ready;
    wire hr_result_ready;
    wire sched_result_ready=WITH_HR_UDP ? hr_result_ready : result_ready;
    history_scheduled_store #(.FRAME_PIXELS(FP),.SLOTS(SLOTS),.WINDOWS(WINDOWS),.BURST(BURST),
        .GAP_DEPTH(GAP_DEPTH),.PRE_MS(PRE_MS),.POST_MS(POST_MS),.BASE_ADDR(BASE_ADDR)) store(
        .clk(clk),.rst(ui_rst),
        .frame_valid(frame_valid),.frame_ready(frame_ready),.frame_fence(frame_fence),.frame_meta(frame_meta),
        .pixel_valid(pixel_valid),.pixel_last(pixel_last),.pixel_data(pixel_data),.pixel_ready(pixel_ready),
        .write_result_valid(write_result_valid),.write_result_ready(write_result_ready),
        .write_result_meta(write_result_meta),.write_result_code(write_result_code),
        .fence_done(fence_done),.fence_ok(fence_ok),
        .request_valid(event_valid && event_ready),.request_ready(store_request_ready),.request_event(event_event),
        .accepted(),.accepted_window(),.accepted_token(),
        .fence_valid(1'b0),.fence_time(64'd0),
        .gap_valid(gap_valid),.gap_ready(gap_ready),.gap_meta(gap_meta),.gap_reason(gap_reason),
        .out_valid(out_valid),.out_sof(out_sof),.out_last(out_last),.out_data(out_data),
        .out_meta(out_meta),.out_event(out_event),.out_index(out_index),.out_ready(out_ready),
        .result_valid(result_valid),.result_ready(sched_result_ready),.result_window(result_window),
        .result_token(result_token),.result_code(result_code),.result_ok(result_ok),
        .result_truncated(result_truncated),.result_capture_error(result_capture_error),
        .result_frames(result_frames),.result_gap_count(result_gap_count),
        .result_gap_unknown(result_gap_unknown),.result_gap_bad_range(result_gap_bad_range),
        .result_coverage_ok(result_coverage_ok),.result_lower(result_lower),.result_upper(result_upper),
        .result_gap_first_meta(result_gap_first_meta),.result_gap_last_meta(result_gap_last_meta),
        .result_gap_first_reason(result_gap_first_reason),.result_gap_last_reason(result_gap_last_reason),
        .result_event(result_event),.scheduler_halted(client_halted),.scheduler_protocol_fault(),
        .pending_windows(pending_windows),.sealed_time(),.gap_recorded(gap_recorded),.gap_evicted(gap_evicted),
        .journal_halted(journal_halted_i),.protected_slots(protected_slots),.faults(faults),
        .token_exhausted(),.window_token_exhausted(),
        .frames_committed(frames_committed),.frames_dropped(frames_dropped),
        .reserve_rejected(reserve_rejected),.write_failed(write_failed),
        .write_beats(),.read_beats(),.done(done),.done_ok(done_ok),
        .m_axi_awid(m_axi_awid),.m_axi_arid(m_axi_arid),.m_axi_awaddr(m_axi_awaddr),.m_axi_araddr(m_axi_araddr),
        .m_axi_awlen(m_axi_awlen),.m_axi_arlen(m_axi_arlen),.m_axi_awsize(m_axi_awsize),.m_axi_arsize(m_axi_arsize),
        .m_axi_awburst(m_axi_awburst),.m_axi_arburst(m_axi_arburst),
        .m_axi_awvalid(m_axi_awvalid),.m_axi_arvalid(m_axi_arvalid),
        .m_axi_awready(m_axi_awready),.m_axi_arready(m_axi_arready),
        .m_axi_wdata(m_axi_wdata),.m_axi_wstrb(m_axi_wstrb),.m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),.m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid),.m_axi_rid(m_axi_rid),.m_axi_bresp(m_axi_bresp),.m_axi_rresp(m_axi_rresp),
        .m_axi_bvalid(m_axi_bvalid),.m_axi_rvalid(m_axi_rvalid),.m_axi_rlast(m_axi_rlast),
        .m_axi_rdata(m_axi_rdata),.m_axi_bready(m_axi_bready),.m_axi_rready(m_axi_rready));
    // Optional one-datagram HR path. When disabled the bridge is held idle and
    // the external merged-result handshake remains authoritative.
    history_result_udp_bridge #(.WINDOWS(WINDOWS),.WW(WW)) hr_bridge(
        .clk(clk),.rst(ui_rst),
        .result_valid(WITH_HR_UDP ? result_valid : 1'b0),.result_ready(hr_result_ready),
        .result_window(result_window),.result_token(result_token),.result_code(result_code),
        .result_ok(result_ok),.result_truncated(result_truncated),.result_capture_error(result_capture_error),
        .result_frames(result_frames),.result_gap_count(result_gap_count),
        .result_gap_unknown(result_gap_unknown),.result_gap_bad_range(result_gap_bad_range),
        .result_coverage_ok(result_coverage_ok),.result_lower(result_lower),.result_upper(result_upper),
        .result_gap_first_meta(result_gap_first_meta),.result_gap_last_meta(result_gap_last_meta),
        .result_gap_first_reason(result_gap_first_reason),.result_gap_last_reason(result_gap_last_reason),
        .result_event(result_event),.tx_qualified(hr_tx_qualified),
        .tx_en_pulse(hr_tx_en_pulse),.data_length(hr_data_length),
        .payload_req(hr_payload_req),.tx_done(hr_tx_done),.payload_data(hr_payload_data),
        .protocol_fault(hr_protocol_fault),.records_sent(hr_records_sent),
        .packets_sent(hr_packets_sent),.packets_dropped(hr_packets_dropped));
    // External request must wait for both scheduler room and store admission.
    assign event_ready=!ui_rst && identity_request_enable && store_request_ready;
    assign journal_halted=journal_halted_i;
    // synthesis translate_off
    initial if(SRC_WIDTH<1 || SRC_HEIGHT<1 || SAMPLE_STRIDE<1 || SRC_WIDTH%SAMPLE_STRIDE ||
        SRC_HEIGHT%SAMPLE_STRIDE || FP<1 || SLOTS<1 || WINDOWS<1) $fatal(1,"FAIL: history client parameters");
    // synthesis translate_on
endmodule
