`timescale 1ns/1ps
// Merged history result -> fixed HR v1 record -> ONE buffered datagram.
// Same-clock only: source and Ethernet must share clk/reset; this wrapper does
// NOT provide the UI->125MHz CDC. The caller owns eth_udp_tx_gmii/tx_qualified.
module history_result_udp_bridge #(
    parameter integer WINDOWS=4,
    parameter integer WW=WINDOWS<2 ? 1 : $clog2(WINDOWS),
    parameter integer REQUIRE_TX_QUALIFIED=0
)(
    input wire clk,rst,
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
    wire record_valid,record_last;
    wire [7:0] record_data;
    wire record_ready,record_fault,bridge_fault;
    history_result_record #(.WINDOWS(WINDOWS),.WW(WW)) record(
        .clk(clk),.rst(rst),.result_valid(result_valid),.result_ready(result_ready),
        .result_window(result_window),.result_token(result_token),.result_code(result_code),
        .result_ok(result_ok),.result_truncated(result_truncated),.result_capture_error(result_capture_error),
        .result_frames(result_frames),.result_gap_count(result_gap_count),
        .result_gap_unknown(result_gap_unknown),.result_gap_bad_range(result_gap_bad_range),
        .result_coverage_ok(result_coverage_ok),.result_lower(result_lower),.result_upper(result_upper),
        .result_gap_first_meta(result_gap_first_meta),.result_gap_last_meta(result_gap_last_meta),
        .result_gap_first_reason(result_gap_first_reason),.result_gap_last_reason(result_gap_last_reason),
        .result_event(result_event),.tx_valid(record_valid),.tx_last(record_last),.tx_data(record_data),
        .tx_ready(record_ready),.protocol_fault(record_fault),.records_sent(records_sent));
    evidence_packet_udp_bridge #(.MAX_PACKET_BYTES(1108),
        .REQUIRE_TX_QUALIFIED(REQUIRE_TX_QUALIFIED)) bridge(
        .clk(clk),.rst(rst),.tx_qualified(tx_qualified),
        .in_valid(record_valid),.in_last(record_last),.in_data(record_data),.in_ready(record_ready),
        .tx_en_pulse(tx_en_pulse),.data_length(data_length),.payload_req(payload_req),
        .tx_done(tx_done),.payload_data(payload_data),.protocol_fault(bridge_fault),
        .packets_sent(packets_sent),.packets_dropped(packets_dropped));
    assign protocol_fault=record_fault || bridge_fault;
    // synthesis translate_off
    initial if(WINDOWS<1 || WW>32) $fatal(1,"FAIL: history result udp parameters");
    // synthesis translate_on
endmodule
