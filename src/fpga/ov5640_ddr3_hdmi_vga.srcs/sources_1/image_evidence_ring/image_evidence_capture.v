`timescale 1ns/1ps

// Pixel-domain image evidence capture: downsample the display stream into a
// low-resolution GRAY8 ring, then serialise a completed event window into a
// header+frame byte stream for the UDP source in the 125 MHz domain.
//
// Byte stream (per frame, WINDOW_LENGTH frames per window):
//   16-byte header: event_seq, frame_index, frame_count(2), frame_id(4),
//                   timestamp_ms(4), config_version, pixel_format, reserved(2)
//   followed by FRAME_PIXELS payload bytes (row-major GRAY8).
module image_evidence_capture #(
    parameter integer FRAME_WIDTH  = 160,
    parameter integer FRAME_HEIGHT = 90,
    parameter integer PRE_FRAMES   = 8,
    parameter integer POST_FRAMES  = 8,
    parameter integer RING_DEPTH   = 32
) (
    input                     clk,
    input                     rst,

    // Display pixel stream.
    input      [7:0]          pixel_r,
    input      [7:0]          pixel_g,
    input      [7:0]          pixel_b,
    input      [11:0]         x,
    input      [11:0]         y,
    input                     de,
    input                     sof,

    // Per-frame metadata from the workflow.
    input      [31:0]         meta_frame_id,
    input      [31:0]         meta_timestamp_ms,
    input      [7:0]          meta_config_version,
    input      [7:0]          meta_event_seq,
    input                     event_trigger,

    // Serialised window stream (valid/ready handshake, pixel clock).
    output reg                out_valid,
    output reg [7:0]          out_data,
    input                     out_ready,

    // Status / observability.
    output                    window_available,
    output                    window_busy,
    output                    window_overrun,
    output reg [7:0]          snapshot_event_seq
);

    localparam integer FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;
    localparam integer WINDOW_LENGTH = PRE_FRAMES + POST_FRAMES + 1;
    localparam integer PIXEL_INDEX_WIDTH =
        (FRAME_PIXELS < 2) ? 1 : $clog2(FRAME_PIXELS);
    localparam integer FRAME_INDEX_WIDTH =
        (WINDOW_LENGTH < 2) ? 1 : $clog2(WINDOW_LENGTH);
    localparam [15:0] WINDOW_LENGTH_V = WINDOW_LENGTH;
    localparam [4:0]  WINDOW_LENGTH_B = WINDOW_LENGTH;
    localparam [PIXEL_INDEX_WIDTH-1:0] FRAME_PIXELS_LAST = FRAME_PIXELS - 1;

    wire                    ds_valid;
    wire                    ds_frame_last;
    wire [PIXEL_INDEX_WIDTH-1:0] ds_pixel_index;
    wire [15:0]             ds_pixel;
    wire [31:0]             ds_frame_id;
    wire [31:0]             ds_timestamp_ms;
    wire [7:0]              ds_config_version;
    wire [7:0]              ds_event_seq;
    wire                    ds_event_trigger;

    image_downsampler #(
        .SRC_WIDTH   (1280),
        .SRC_HEIGHT  (720),
        .FRAME_WIDTH (FRAME_WIDTH),
        .FRAME_HEIGHT(FRAME_HEIGHT)
    ) downsampler (
        .clk                 (clk),
        .rst                 (rst),
        .pixel_r             (pixel_r),
        .pixel_g             (pixel_g),
        .pixel_b             (pixel_b),
        .x                   (x),
        .y                   (y),
        .de                  (de),
        .sof                 (sof),
        .meta_frame_id       (meta_frame_id),
        .meta_timestamp_ms   (meta_timestamp_ms),
        .meta_config_version (meta_config_version),
        .meta_event_seq      (meta_event_seq),
        .event_trigger       (event_trigger),
        .sample_valid        (ds_valid),
        .frame_last          (ds_frame_last),
        .sample_pixel_index  (ds_pixel_index),
        .sample_pixel        (ds_pixel),
        .sample_frame_id     (ds_frame_id),
        .sample_timestamp_ms (ds_timestamp_ms),
        .sample_config_version(ds_config_version),
        .sample_event_seq    (ds_event_seq),
        .sample_event_trigger(ds_event_trigger)
    );

    reg                          readout_active;
    wire                         ring_available;
    wire                         ring_busy;
    wire                         ring_overrun;
    wire [7:0]                   ring_snapshot_seq;
    wire                         ring_read_valid;
    wire [15:0]                  ring_read_pixel;
    wire [31:0]                  ring_read_frame_id;
    wire [31:0]                  ring_read_timestamp_ms;
    wire [7:0]                   ring_read_config_version;
    reg                          ring_read_req;
    reg  [FRAME_INDEX_WIDTH-1:0] ring_read_frame_index;
    reg  [PIXEL_INDEX_WIDTH-1:0] ring_read_pixel_index;

    image_evidence_ring #(
        .FRAME_WIDTH  (FRAME_WIDTH),
        .FRAME_HEIGHT (FRAME_HEIGHT),
        .PIXEL_WIDTH  (16),
        .PRE_FRAMES   (PRE_FRAMES),
        .POST_FRAMES  (POST_FRAMES),
        .RING_DEPTH   (RING_DEPTH)
    ) ring (
        .clk                  (clk),
        .rst                  (rst),
        .sample_valid         (ds_valid),
        .frame_last           (ds_frame_last),
        .sample_pixel_index   (ds_pixel_index),
        .sample_pixel         (ds_pixel),
        .sample_frame_id      (ds_frame_id),
        .sample_timestamp_ms  (ds_timestamp_ms),
        .sample_config_version(ds_config_version),
        .sample_event_seq     (ds_event_seq),
        .event_trigger        (ds_event_trigger),
        .readout_active       (readout_active),
        .frame_busy           (ring_busy),
        .frame_done           (),
        .frame_available      (ring_available),
        .image_evidence_overrun(ring_overrun),
        .snapshot_event_seq   (ring_snapshot_seq),
        .read_req             (ring_read_req),
        .read_frame_index     (ring_read_frame_index),
        .read_pixel_index     (ring_read_pixel_index),
        .read_valid           (ring_read_valid),
        .read_pixel           (ring_read_pixel),
        .read_frame_id        (ring_read_frame_id),
        .read_timestamp_ms    (ring_read_timestamp_ms),
        .read_config_version  (ring_read_config_version)
    );

    assign window_available = ring_available;
    assign window_busy      = ring_busy;
    assign window_overrun   = ring_overrun;

    localparam [3:0] S_IDLE      = 4'd0;
    localparam [3:0] S_META_REQ  = 4'd1;
    localparam [3:0] S_META_WAIT = 4'd2;
    localparam [3:0] S_HEADER    = 4'd3;
    localparam [3:0] S_PIXEL0    = 4'd4;
    localparam [3:0] S_PIX_REQ   = 4'd5;
    localparam [3:0] S_PIX_WAIT  = 4'd6;
    localparam [3:0] S_PIX_SEND  = 4'd7;
    localparam [3:0] S_NEXT_FRAME= 4'd8;

    reg [3:0]  state;
    reg [4:0]  fr;
    reg [PIXEL_INDEX_WIDTH-1:0] px;
    reg [4:0]  hdr_idx;
    reg [4:0]  next_fr;
    reg [7:0]  meta_id [0:3];
    reg [7:0]  meta_ts [0:3];
    reg [7:0]  meta_cfg;
    reg [15:0] pix0;
    reg [15:0] pix_hold;
    reg        pix_byte_sel;

    wire out_fire = out_valid && out_ready;

    function [7:0] header_byte;
        input [4:0] idx;
        begin
            case (idx)
                5'd0:  header_byte = snapshot_event_seq;
                5'd1:  header_byte = {3'd0, fr};
                5'd2:  header_byte = WINDOW_LENGTH_V[15:8];
                5'd3:  header_byte = WINDOW_LENGTH_V[7:0];
                5'd4:  header_byte = meta_id[3];
                5'd5:  header_byte = meta_id[2];
                5'd6:  header_byte = meta_id[1];
                5'd7:  header_byte = meta_id[0];
                5'd8:  header_byte = meta_ts[3];
                5'd9:  header_byte = meta_ts[2];
                5'd10: header_byte = meta_ts[1];
                5'd11: header_byte = meta_ts[0];
                5'd12: header_byte = meta_cfg;
                5'd13: header_byte = 8'd1; // RGB565
                5'd14: header_byte = 8'd0;
                default: header_byte = 8'd0;
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            state                 <= S_IDLE;
            fr                    <= 5'd0;
            px                    <= {PIXEL_INDEX_WIDTH{1'b0}};
            hdr_idx               <= 5'd0;
            next_fr               <= 5'd0;
            meta_cfg              <= 8'd0;
            pix0                  <= 16'd0;
            pix_hold              <= 16'd0;
            pix_byte_sel          <= 1'b0;
            readout_active        <= 1'b0;
            ring_read_req         <= 1'b0;
            ring_read_frame_index <= {FRAME_INDEX_WIDTH{1'b0}};
            ring_read_pixel_index <= {PIXEL_INDEX_WIDTH{1'b0}};
            out_valid             <= 1'b0;
            out_data              <= 8'd0;
            snapshot_event_seq    <= 8'd0;
        end else begin
            ring_read_req <= 1'b0;

            case (state)
                S_IDLE: begin
                    out_valid      <= 1'b0;
                    readout_active <= 1'b0;
                    if (ring_available) begin
                        snapshot_event_seq <= ring_snapshot_seq;
                        readout_active     <= 1'b1;
                        fr                 <= 5'd0;
                        state              <= S_META_REQ;
                    end
                end

                S_META_REQ: begin
                    ring_read_frame_index <= fr[FRAME_INDEX_WIDTH-1:0];
                    ring_read_pixel_index <= {PIXEL_INDEX_WIDTH{1'b0}};
                    ring_read_req         <= 1'b1;
                    state                 <= S_META_WAIT;
                end

                S_META_WAIT: begin
                    if (ring_read_valid) begin
                        meta_id[3] <= ring_read_frame_id[31:24];
                        meta_id[2] <= ring_read_frame_id[23:16];
                        meta_id[1] <= ring_read_frame_id[15:8];
                        meta_id[0] <= ring_read_frame_id[7:0];
                        meta_ts[3] <= ring_read_timestamp_ms[31:24];
                        meta_ts[2] <= ring_read_timestamp_ms[23:16];
                        meta_ts[1] <= ring_read_timestamp_ms[15:8];
                        meta_ts[0] <= ring_read_timestamp_ms[7:0];
                        meta_cfg   <= ring_read_config_version;
                        pix0       <= ring_read_pixel;
                        hdr_idx    <= 5'd0;
                        state      <= S_HEADER;
                    end
                end

                S_HEADER: begin
                    if (!out_valid) begin
                        out_data  <= header_byte(hdr_idx);
                        out_valid <= 1'b1;
                    end else if (out_fire) begin
                        out_valid <= 1'b0;
                        if (hdr_idx == 5'd15)
                            state <= S_PIXEL0;
                        else
                            hdr_idx <= hdr_idx + 5'd1;
                    end
                end

                S_PIXEL0: begin
                    if (!out_valid) begin
                        out_data  <= pix_byte_sel ? pix0[7:0] : pix0[15:8];
                        out_valid <= 1'b1;
                    end else if (out_fire) begin
                        out_valid <= 1'b0;
                        if (!pix_byte_sel) begin
                            pix_byte_sel <= 1'b1;
                        end else begin
                            pix_byte_sel <= 1'b0;
                            if (FRAME_PIXELS == 1) begin
                                next_fr <= fr + 5'd1;
                                state   <= S_NEXT_FRAME;
                            end else begin
                                px    <= {{(PIXEL_INDEX_WIDTH-1){1'b0}}, 1'b1};
                                state <= S_PIX_REQ;
                            end
                        end
                    end
                end

                S_PIX_REQ: begin
                    ring_read_frame_index <= fr[FRAME_INDEX_WIDTH-1:0];
                    ring_read_pixel_index <= px;
                    ring_read_req         <= 1'b1;
                    state                 <= S_PIX_WAIT;
                end

                S_PIX_WAIT: begin
                    if (ring_read_valid) begin
                        pix_hold <= ring_read_pixel;
                        state    <= S_PIX_SEND;
                    end
                end

                S_PIX_SEND: begin
                    if (!out_valid) begin
                        out_data  <= pix_byte_sel ? pix_hold[7:0] : pix_hold[15:8];
                        out_valid <= 1'b1;
                    end else if (out_fire) begin
                        out_valid <= 1'b0;
                        if (!pix_byte_sel) begin
                            pix_byte_sel <= 1'b1;
                        end else begin
                            pix_byte_sel <= 1'b0;
                            if (px == FRAME_PIXELS_LAST) begin
                                next_fr <= fr + 5'd1;
                                state   <= S_NEXT_FRAME;
                            end else begin
                                px    <= px + 1'b1;
                                state <= S_PIX_REQ;
                            end
                        end
                    end
                end

                S_NEXT_FRAME: begin
                    if (next_fr >= WINDOW_LENGTH_B) begin
                        out_valid      <= 1'b0;
                        readout_active <= 1'b0;
                        state          <= S_IDLE;
                    end else begin
                        fr    <= next_fr;
                        state <= S_META_REQ;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
