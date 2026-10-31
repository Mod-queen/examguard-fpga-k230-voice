`timescale 1ns/1ps

// Bridges the packetizer stream to the ACX750 UDP TX contract used by the
// local ch53 example: start pulse, fixed payload length, read request, done.
// The packet buffer is intentionally independent from the camera/DDR3 path.
module image_evidence_udp_tx_bridge #(
    parameter integer MAX_PAYLOAD_BYTES = 1024,
    parameter integer MAX_PACKET_BYTES  = MAX_PAYLOAD_BYTES + 36
) (
    input         clk,
    input         rst,

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

    // Existing eth_udp_tx_gmii application-side contract.
    output reg        tx_en_pulse,
    input             tx_done,
    output [15:0]     data_length,
    input             payload_req,
    output [7:0]      payload_data,
    output reg        frame_done
);

    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_CAPTURE = 2'd1;
    localparam [1:0] S_WAIT_TX = 2'd2;
    localparam [1:0] S_TX = 2'd3;

    reg [1:0] state;
    reg [15:0] packet_length;
    reg [15:0] capture_count;
    reg [15:0] read_count;
    reg        last_packet;
    reg [7:0] packet_mem [0:MAX_PACKET_BYTES-1];

    wire packetizer_valid;
    wire [7:0] packetizer_data;
    wire packetizer_last;
    wire packetizer_ready;
    wire packetizer_frame_ready;
    wire packetizer_busy;
    wire packetizer_frame_done;

    image_evidence_udp_packetizer #(
        .MAX_PAYLOAD_BYTES(MAX_PAYLOAD_BYTES)
    ) packetizer (
        .clk              (clk),
        .rst              (rst),
        .start_frame      (start_frame && (state == S_IDLE)),
        .event_seq        (event_seq),
        .frame_index      (frame_index),
        .frame_count      (frame_count),
        .frame_id         (frame_id),
        .timestamp_ms     (timestamp_ms),
        .config_version   (config_version),
        .frame_width      (frame_width),
        .frame_height     (frame_height),
        .frame_length     (frame_length),
        .start_ready      (),
        .frame_byte_valid (frame_byte_valid && (state == S_CAPTURE)),
        .frame_byte       (frame_byte),
        .frame_byte_ready (packetizer_frame_ready),
        .tx_valid         (packetizer_valid),
        .tx_data          (packetizer_data),
        .tx_last          (packetizer_last),
        .tx_ready         (packetizer_ready),
        .busy             (packetizer_busy),
        .frame_done       (packetizer_frame_done)
    );

    assign start_ready = (state == S_IDLE);
    assign frame_byte_ready = (state == S_CAPTURE) && packetizer_frame_ready;
    assign packetizer_ready = (state == S_CAPTURE) &&
                              (capture_count < MAX_PACKET_BYTES);
    assign data_length = packet_length;
    assign payload_data = (read_count < packet_length) ? packet_mem[read_count] :
                          8'd0;

    always @(posedge clk) begin
        if (rst) begin
            state         <= S_IDLE;
            packet_length <= 16'd0;
            capture_count <= 16'd0;
            read_count    <= 16'd0;
            last_packet   <= 1'b0;
            tx_en_pulse   <= 1'b0;
            frame_done    <= 1'b0;
        end else begin
            tx_en_pulse <= 1'b0;
            frame_done  <= 1'b0;

            if (packetizer_valid && packetizer_ready) begin
                packet_mem[capture_count] <= packetizer_data;
                capture_count <= capture_count + 1'b1;
                if (packetizer_last) begin
                    packet_length <= capture_count + 1'b1;
                    last_packet   <= packetizer_frame_done;
                    state         <= S_WAIT_TX;
                end
            end

            case (state)
                S_IDLE: begin
                    if (start_frame && (frame_length != 0)) begin
                        capture_count <= 16'd0;
                        state <= S_CAPTURE;
                    end
                end

                S_CAPTURE: begin
                    // The packetizer is paused by packetizer_ready after the
                    // last CRC byte. The buffered UDP chunk is sent first.
                end

                S_WAIT_TX: begin
                    tx_en_pulse <= 1'b1;
                    if (packetizer_frame_done)
                        last_packet <= 1'b1;
                    read_count  <= 16'd0;
                    state       <= S_TX;
                end

                S_TX: begin
                    if (payload_req && (read_count < packet_length))
                        read_count <= read_count + 1'b1;
                    if (tx_done) begin
                        if (last_packet) begin
                            frame_done <= 1'b1;
                            state      <= S_IDLE;
                        end else begin
                            capture_count <= 16'd0;
                            state         <= S_CAPTURE;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
