`timescale 1ns/1ps
// HR result record (UI) -> byte+last CDC -> UDP bridge (Ethernet clock).
// The destination bridge buffers the whole datagram before Ethernet starts.
// src_rst/dst_rst MUST assert together from a shared cancellation barrier and
// release locally; this module is not a standalone reset synchronizer.
module history_result_udp_cdc #(
    parameter integer WINDOWS=4,
    parameter integer WW=WINDOWS<2 ? 1 : $clog2(WINDOWS),
    parameter integer DEPTH=256,
    parameter integer REQUIRE_TX_QUALIFIED=0
)(
    input wire src_clk,src_rst,dst_clk,dst_rst,
    input wire result_valid,output wire result_ready,
    input wire [WW-1:0] result_window,input wire [31:0] result_token,
    input wire [2:0] result_code,
    input wire result_ok,result_truncated,result_capture_error,
    input wire [31:0] result_frames,result_gap_count,
    input wire result_gap_unknown,result_gap_bad_range,result_coverage_ok,
    input wire [63:0] result_lower,result_upper,
    input wire [95:0] result_gap_first_meta,result_gap_last_meta,
    input wire [7:0] result_gap_first_reason,result_gap_last_reason,
    input wire [255:0] result_event,
    input wire tx_qualified,
    output wire tx_en_pulse,output wire [15:0] data_length,
    input wire payload_req,tx_done,output wire [7:0] payload_data,
    output wire protocol_fault,
    output wire [31:0] records_sent,packets_sent,packets_dropped
);
    wire rec_valid,rec_last,rec_ready;
    wire [7:0] rec_data;
    wire cdc_valid,cdc_last,cdc_ready;
    wire [7:0] cdc_data;
    wire rec_fault,bridge_fault;
    history_result_record #(.WINDOWS(WINDOWS),.WW(WW)) record(
        .clk(src_clk),.rst(src_rst),.result_valid(result_valid),.result_ready(result_ready),
        .result_window(result_window),.result_token(result_token),.result_code(result_code),
        .result_ok(result_ok),.result_truncated(result_truncated),.result_capture_error(result_capture_error),
        .result_frames(result_frames),.result_gap_count(result_gap_count),
        .result_gap_unknown(result_gap_unknown),.result_gap_bad_range(result_gap_bad_range),
        .result_coverage_ok(result_coverage_ok),.result_lower(result_lower),.result_upper(result_upper),
        .result_gap_first_meta(result_gap_first_meta),.result_gap_last_meta(result_gap_last_meta),
        .result_gap_first_reason(result_gap_first_reason),.result_gap_last_reason(result_gap_last_reason),
        .result_event(result_event),.tx_valid(rec_valid),.tx_last(rec_last),.tx_data(rec_data),
        .tx_ready(rec_ready),.protocol_fault(rec_fault),.records_sent(records_sent));
    evidence_packet_cdc #(.DEPTH(DEPTH)) packet_cdc(
        .src_clk(src_clk),.src_rst(src_rst),.src_valid(rec_valid),.src_last(rec_last),
        .src_data(rec_data),.src_ready(rec_ready),
        .dst_clk(dst_clk),.dst_rst(dst_rst),.dst_ready(cdc_ready),
        .dst_valid(cdc_valid),.dst_data(cdc_data),.dst_last(cdc_last));
    evidence_packet_udp_bridge #(.MAX_PACKET_BYTES(1108),
        .REQUIRE_TX_QUALIFIED(REQUIRE_TX_QUALIFIED)) bridge(
        .clk(dst_clk),.rst(dst_rst),.tx_qualified(tx_qualified),
        .in_valid(cdc_valid),.in_last(cdc_last),.in_data(cdc_data),.in_ready(cdc_ready),
        .tx_en_pulse(tx_en_pulse),.data_length(data_length),.payload_req(payload_req),
        .tx_done(tx_done),.payload_data(payload_data),.protocol_fault(bridge_fault),
        .packets_sent(packets_sent),.packets_dropped(packets_dropped));
    assign protocol_fault=rec_fault || bridge_fault;
    // synthesis translate_off
    initial if(WINDOWS<1 || WW>32 || DEPTH<1) $fatal(1,"FAIL: history result udp cdc parameters");
    // synthesis translate_on
endmodule
