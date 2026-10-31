`timescale 1ns/1ps

// 125 MHz side of the image evidence path. Consumes the serialised window byte
// stream produced by image_evidence_capture (crossed by cdc_byte_channel),
// parses the per-frame 16-byte header, and drives the ACX750 UDP transmitter
// one image frame at a time.
module image_evidence_udp_source #(
    parameter integer FRAME_WIDTH  = 160,
    parameter integer FRAME_HEIGHT = 90,
    parameter integer WINDOW_LENGTH = 17
) (
    input             clk125m,
    input             reset_p,

    // Byte stream from the pixel domain (already synchronised).
    input             byte_valid,
    input      [7:0]  byte_data,
    output            byte_ack,

    // Application metadata to the UDP bridge.
    output reg        start_frame,
    output     [7:0]  event_seq,
    output     [7:0]  frame_index,
    output     [15:0] frame_count,
    output     [31:0] frame_id,
    output     [31:0] timestamp_ms,
    output     [7:0]  config_version,
    output     [15:0] frame_width,
    output     [15:0] frame_height,
    output     [31:0] frame_length,
    input             start_ready,

    output reg        frame_byte_valid,
    output     [7:0]  frame_byte,
    input             frame_byte_ready,

    output reg        busy
);

    localparam integer FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;
    localparam integer FRAME_BYTES  = FRAME_PIXELS * 2; // RGB565
    localparam integer BYTE_INDEX_WIDTH =
        (FRAME_BYTES < 2) ? 1 : $clog2(FRAME_BYTES);
    localparam [BYTE_INDEX_WIDTH-1:0] FRAME_BYTES_LAST = FRAME_BYTES - 1;

    localparam [1:0] S_HEADER = 2'd0;
    localparam [1:0] S_START  = 2'd1;
    localparam [1:0] S_PAYLOAD= 2'd2;

    reg [1:0]  state;
    reg [3:0]  hidx;
    reg [BYTE_INDEX_WIDTH-1:0] px;
    reg [15:0] frame_left;
    reg [7:0]  hdr [0:15];

    assign event_seq     = hdr[0];
    assign frame_index   = hdr[1];
    assign frame_count   = {hdr[2], hdr[3]};
    assign frame_id      = {hdr[4], hdr[5], hdr[6], hdr[7]};
    assign timestamp_ms  = {hdr[8], hdr[9], hdr[10], hdr[11]};
    assign config_version= hdr[12];
    assign frame_width   = FRAME_WIDTH[15:0];
    assign frame_height  = FRAME_HEIGHT[15:0];
    assign frame_length  = FRAME_PIXELS * 2; // RGB565: two bytes per pixel

    assign frame_byte = byte_data;

    // The byte presented to the packetizer is valid whenever a payload byte is
    // available on the channel.
    always @(*) begin
        frame_byte_valid = (state == S_PAYLOAD) && byte_valid;
    end

    // A byte is consumed in the same cycle it is read, so the acknowledge to
    // the CDC has no one-cycle delay (which would otherwise consume it twice).
    assign byte_ack = ((state == S_HEADER) && byte_valid) ||
                      ((state == S_PAYLOAD) && byte_valid && frame_byte_ready);

    always @(posedge clk125m) begin
        if (reset_p) begin
            state            <= S_HEADER;
            hidx             <= 4'd0;
            px               <= {BYTE_INDEX_WIDTH{1'b0}};
            frame_left       <= WINDOW_LENGTH[15:0];
            start_frame      <= 1'b0;
            busy             <= 1'b0;
        end else begin
            start_frame      <= 1'b0;

            case (state)
                S_HEADER: begin
                    busy <= 1'b1;
                    if (byte_valid) begin
                        hdr[hidx] <= byte_data;
                        if (hidx == 4'd15) begin
                            hidx  <= 4'd0;
                            state <= S_START;
                        end else begin
                            hidx  <= hidx + 4'd1;
                        end
                    end
                end

                S_START: begin
                    if (!start_frame) begin
                        start_frame <= 1'b1;
                    end else if (start_ready) begin
                        start_frame <= 1'b0;
                        px          <= {BYTE_INDEX_WIDTH{1'b0}};
                        state       <= S_PAYLOAD;
                    end
                end

                S_PAYLOAD: begin
                    if (byte_valid && frame_byte_ready) begin
                        if (px == FRAME_BYTES_LAST) begin
                            px <= {BYTE_INDEX_WIDTH{1'b0}};
                            if (frame_left <= 16'd1) begin
                                frame_left <= WINDOW_LENGTH[15:0];
                                state      <= S_HEADER;
                            end else begin
                                frame_left <= frame_left - 16'd1;
                                state      <= S_HEADER;
                            end
                        end else begin
                            px <= px + 1'b1;
                        end
                    end
                end

                default: state <= S_HEADER;
            endcase
        end
    end

endmodule

