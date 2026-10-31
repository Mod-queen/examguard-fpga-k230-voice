`timescale 1ns/1ps

// Application-level packetizer for the FPGA -> PC image evidence path.
// This module stops at a byte-stream interface.  The ACX750-specific UDP
// stack consumes tx_data/tx_valid/tx_last after this boundary.
module image_evidence_udp_packetizer #(
    parameter integer MAX_PAYLOAD_BYTES = 1024
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

    output        tx_valid,
    output [7:0]  tx_data,
    output        tx_last,
    input         tx_ready,
    output        busy,
    output reg    frame_done
);

    localparam [1:0] S_IDLE    = 2'd0;
    localparam [1:0] S_HEADER  = 2'd1;
    localparam [1:0] S_PAYLOAD = 2'd2;
    localparam [1:0] S_CRC    = 2'd3;

    reg [1:0] state;
    reg [5:0] header_pos;
    reg [1:0] crc_pos;
    reg [15:0] payload_pos;
    reg [15:0] packet_payload_len;
    reg [31:0] frame_remaining;
    reg [31:0] packet_offset;
    reg [31:0] crc_reg;

    reg [7:0]  event_seq_reg;
    reg [7:0]  frame_index_reg;
    reg [15:0] frame_count_reg;
    reg [31:0] frame_id_reg;
    reg [31:0] timestamp_reg;
    reg [7:0]  config_version_reg;
    reg [15:0] frame_width_reg;
    reg [15:0] frame_height_reg;

    function [15:0] payload_size;
        input [31:0] remaining;
        begin
            if (remaining > MAX_PAYLOAD_BYTES)
                payload_size = MAX_PAYLOAD_BYTES;
            else
                payload_size = remaining[15:0];
        end
    endfunction

    function [31:0] crc32_byte;
        input [31:0] crc_in;
        input [7:0]  data_in;
        reg [31:0] c;
        reg mix;
        integer bit_index;
        begin
            c = crc_in;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                mix = c[0] ^ data_in[bit_index];
                c = c >> 1;
                if (mix)
                    c = c ^ 32'hEDB88320;
            end
            crc32_byte = c;
        end
    endfunction

    function [7:0] header_byte;
        input [5:0] pos;
        begin
            case (pos)
                6'd0:  header_byte = 8'h50; // P
                6'd1:  header_byte = 8'h47; // G
                6'd2:  header_byte = 8'd1;
                6'd3:  header_byte = 8'd1; // image frame
                6'd4:  header_byte = 8'd0;
                6'd5:  header_byte = 8'd32;
                6'd6:  header_byte = event_seq_reg;
                6'd7:  header_byte = frame_index_reg;
                6'd8:  header_byte = frame_count_reg[15:8];
                6'd9:  header_byte = frame_count_reg[7:0];
                6'd10: header_byte = packet_offset[31:24];
                6'd11: header_byte = packet_offset[23:16];
                6'd12: header_byte = packet_offset[15:8];
                6'd13: header_byte = packet_offset[7:0];
                6'd14: header_byte = packet_payload_len[15:8];
                6'd15: header_byte = packet_payload_len[7:0];
                6'd16: header_byte = frame_id_reg[31:24];
                6'd17: header_byte = frame_id_reg[23:16];
                6'd18: header_byte = frame_id_reg[15:8];
                6'd19: header_byte = frame_id_reg[7:0];
                6'd20: header_byte = timestamp_reg[31:24];
                6'd21: header_byte = timestamp_reg[23:16];
                6'd22: header_byte = timestamp_reg[15:8];
                6'd23: header_byte = timestamp_reg[7:0];
                6'd24: header_byte = config_version_reg;
                6'd25: header_byte = 8'd1; // RGB565
                6'd26: header_byte = frame_width_reg[15:8];
                6'd27: header_byte = frame_width_reg[7:0];
                6'd28: header_byte = frame_height_reg[15:8];
                6'd29: header_byte = frame_height_reg[7:0];
                default: header_byte = 8'd0;
            endcase
        end
    endfunction

    // Standard reflected CRC-32 (zlib): accumulate with init 0xFFFFFFFF and
    // invert the register when the four CRC bytes are emitted.
    wire [31:0] crc_final = ~crc_reg;

    assign start_ready      = (state == S_IDLE);
    assign busy             = (state != S_IDLE);
    assign frame_byte_ready = (state == S_PAYLOAD) && tx_ready;
    assign tx_valid         = (state == S_HEADER) || (state == S_CRC) ||
                              ((state == S_PAYLOAD) && frame_byte_valid);
    assign tx_data          = (state == S_HEADER) ? header_byte(header_pos) :
                              (state == S_PAYLOAD) ? frame_byte :
                              (crc_pos == 2'd0) ? crc_final[31:24] :
                              (crc_pos == 2'd1) ? crc_final[23:16] :
                              (crc_pos == 2'd2) ? crc_final[15:8] : crc_final[7:0];
    assign tx_last          = (state == S_CRC) && (crc_pos == 2'd3);

    always @(posedge clk) begin
        if (rst) begin
            state              <= S_IDLE;
            header_pos         <= 6'd0;
            crc_pos            <= 2'd0;
            payload_pos        <= 16'd0;
            packet_payload_len <= 16'd0;
            frame_remaining    <= 32'd0;
            packet_offset      <= 32'd0;
            crc_reg            <= 32'd0;
            event_seq_reg      <= 8'd0;
            frame_index_reg    <= 8'd0;
            frame_count_reg    <= 16'd0;
            frame_id_reg       <= 32'd0;
            timestamp_reg      <= 32'd0;
            config_version_reg <= 8'd0;
            frame_width_reg    <= 16'd0;
            frame_height_reg   <= 16'd0;
            frame_done         <= 1'b0;
        end else begin
            frame_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start_frame && (frame_length != 0)) begin
                        event_seq_reg      <= event_seq;
                        frame_index_reg    <= frame_index;
                        frame_count_reg    <= frame_count;
                        frame_id_reg       <= frame_id;
                        timestamp_reg      <= timestamp_ms;
                        config_version_reg <= config_version;
                        frame_width_reg    <= frame_width;
                        frame_height_reg   <= frame_height;
                        frame_remaining    <= frame_length;
                        packet_offset      <= 32'd0;
                        packet_payload_len <= payload_size(frame_length);
                        header_pos         <= 6'd0;
                        crc_reg            <= 32'hFFFFFFFF;
                        state              <= S_HEADER;
                    end
                end

                S_HEADER: begin
                    if (tx_ready) begin
                        crc_reg <= crc32_byte(crc_reg, header_byte(header_pos));
                        if (header_pos == 6'd31) begin
                            payload_pos <= 16'd0;
                            state       <= S_PAYLOAD;
                        end else begin
                            header_pos <= header_pos + 1'b1;
                        end
                    end
                end

                S_PAYLOAD: begin
                    if (frame_byte_valid && tx_ready) begin
                        crc_reg <= crc32_byte(crc_reg, frame_byte);
                        if (payload_pos + 1'b1 >= packet_payload_len) begin
                            crc_pos <= 2'd0;
                            state   <= S_CRC;
                        end else begin
                            payload_pos <= payload_pos + 1'b1;
                        end
                    end
                end

                S_CRC: begin
                    if (tx_ready) begin
                        if (crc_pos == 2'd3) begin
                            if (frame_remaining > packet_payload_len) begin
                                frame_remaining    <= frame_remaining - packet_payload_len;
                                packet_offset      <= packet_offset + packet_payload_len;
                                packet_payload_len <= payload_size(
                                    frame_remaining - packet_payload_len);
                                header_pos         <= 6'd0;
                                crc_reg            <= 32'hFFFFFFFF;
                                state              <= S_HEADER;
                            end else begin
                                frame_done <= 1'b1;
                                state      <= S_IDLE;
                            end
                        end else begin
                            crc_pos <= crc_pos + 1'b1;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
