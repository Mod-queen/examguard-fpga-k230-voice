`timescale 1ns/1ps

// TX-only ACX750 integration boundary.
// The UDP formatter and RGMII serializer are supplied by the local ch53
// Xilinx-compatible reference project. This top is intentionally separate
// from the verified camera/DDR3/HDMI top until board-level Ethernet checks pass.
module image_evidence_udp_acx750_tx #(
    parameter [47:0] DST_MAC  = 48'hff_ff_ff_ff_ff_ff,
    parameter [47:0] SRC_MAC  = 48'h02_00_00_00_00_02,
    parameter [31:0] DST_IP   = 32'hc0_a8_00_03,
    parameter [31:0] SRC_IP   = 32'hc0_a8_00_02,
    parameter [15:0] DST_PORT = 16'd6102,
    parameter [15:0] SRC_PORT = 16'd5000,
    parameter integer MAX_PAYLOAD_BYTES = 1024,
    parameter integer MAX_PACKET_BYTES  = 1060
) (
    input         clk125m,
    input         reset_p,

    input         start_frame,
    input  [7:0]  event_seq,
    input  [7:0]  frame_index,
    input  [15:0] frame_count,
    input  [31:0] frame_id,
    input  [31:0] timestamp_ms,
    input  [7:0]  config_version,
    input  [15:0] frame_width,
    input  [15:0] frame_height,
    input  [31:0] frame_length,
    output        start_ready,
    input         frame_byte_valid,
    input  [7:0]  frame_byte,
    output        frame_byte_ready,
    output        frame_done,

    output        eth_rst_n,
    output        rgmii_gtxc,
    output [3:0]  rgmii_txd,
    output        rgmii_txen
);

    wire        tx_en_pulse;
    wire        tx_done;
    wire [15:0] data_length;
    wire        payload_req;
    wire [7:0]  payload_data;
    wire        gmii_tx_clk;
    wire [7:0]  gmii_txd;
    wire        gmii_txen;

    assign eth_rst_n = ~reset_p;

    image_evidence_udp_tx_bridge #(
        .MAX_PAYLOAD_BYTES (MAX_PAYLOAD_BYTES),
        .MAX_PACKET_BYTES  (MAX_PACKET_BYTES)
    ) packet_bridge (
        .clk              (clk125m),
        .rst              (reset_p),
        .start_frame      (start_frame),
        .event_seq        (event_seq),
        .frame_index      (frame_index),
        .frame_count      (frame_count),
        .frame_id         (frame_id),
        .timestamp_ms     (timestamp_ms),
        .config_version   (config_version),
        .frame_width      (frame_width),
        .frame_height     (frame_height),
        .frame_length     (frame_length),
        .start_ready      (start_ready),
        .frame_byte_valid (frame_byte_valid),
        .frame_byte       (frame_byte),
        .frame_byte_ready (frame_byte_ready),
        .tx_en_pulse      (tx_en_pulse),
        .tx_done           (tx_done),
        .data_length      (data_length),
        .payload_req      (payload_req),
        .payload_data     (payload_data),
        .frame_done       (frame_done)
    );

    eth_udp_tx_gmii udp_tx (
        .clk125m       (clk125m),
        .reset_p       (reset_p),
        .tx_en_pulse   (tx_en_pulse),
        .tx_done       (tx_done),
        .dst_mac       (DST_MAC),
        .src_mac       (SRC_MAC),
        .dst_ip        (DST_IP),
        .src_ip        (SRC_IP),
        .dst_port      (DST_PORT),
        .src_port      (SRC_PORT),
        .data_length   (data_length),
        .payload_req_o (payload_req),
        .payload_dat_i (payload_data),
        .gmii_tx_clk   (gmii_tx_clk),
        .gmii_txen     (gmii_txen),
        .gmii_txd      (gmii_txd)
    );

    gmii_to_rgmii gmii_to_rgmii_tx (
        .reset_n       (eth_rst_n),
        .gmii_tx_clk   (gmii_tx_clk),
        .gmii_txd      (gmii_txd),
        .gmii_txen     (gmii_txen),
        .gmii_txer     (1'b0),
        .rgmii_tx_clk  (rgmii_gtxc),
        .rgmii_txd     (rgmii_txd),
        .rgmii_txen    (rgmii_txen)
    );

endmodule
