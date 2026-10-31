`timescale 1ns/1ps

// Converts the 1280x720 display pixel stream into a low-resolution GRAY8
// evidence frame by taking one sample per 8x8 block (160x90). The block-decoded
// index is row-major so the consumer can store the frame as a flat buffer.
//
// This is intentionally outside the camera -> DDR3 -> HDMI chain: it is a
// read-only tap on the already verified display pixels.
module image_downsampler #(
    parameter integer SRC_WIDTH       = 1280,
    parameter integer SRC_HEIGHT      = 720,
    parameter integer FRAME_WIDTH     = 160,
    parameter integer FRAME_HEIGHT    = 90,
    parameter integer SAMPLE_SHIFT    = 8,
    parameter integer PIXEL_INDEX_WIDTH =
        ((FRAME_WIDTH * FRAME_HEIGHT) < 2) ? 1 :
        $clog2(FRAME_WIDTH * FRAME_HEIGHT)
) (
    input                     clk,
    input                     rst,

    // Display pixel stream (camera pixels, before the status overlay).
    input      [7:0]          pixel_r,
    input      [7:0]          pixel_g,
    input      [7:0]          pixel_b,
    input      [11:0]         x,
    input      [11:0]         y,
    input                     de,
    input                     sof,

    // Per-frame metadata, held stable for the whole frame by the top level.
    input      [31:0]         meta_frame_id,
    input      [31:0]         meta_timestamp_ms,
    input      [7:0]          meta_config_version,
    input      [7:0]          meta_event_seq,
    input                     event_trigger,

    // Ring write interface.
    output reg                sample_valid,
    output reg                frame_last,
    output reg [PIXEL_INDEX_WIDTH-1:0] sample_pixel_index,
    output reg [15:0]         sample_pixel,
    output     [31:0]         sample_frame_id,
    output     [31:0]         sample_timestamp_ms,
    output     [7:0]          sample_config_version,
    output     [7:0]          sample_event_seq,
    output                    sample_event_trigger
);

    localparam integer FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;
    localparam integer SHIFT_LOG2   = $clog2(SAMPLE_SHIFT);

    wire sample_en = de &&
                     (x[SHIFT_LOG2-1:0] == {SHIFT_LOG2{1'b0}}) &&
                     (y[SHIFT_LOG2-1:0] == {SHIFT_LOG2{1'b0}});
    // RGB565 evidence pixel: the camera is already RGB565, so this is a
    // straightforward repack of the (enhanced) 8-bit display channels.
    wire [15:0] rgb565 = {pixel_r[7:3], pixel_g[7:2], pixel_b[7:3]};

    reg [PIXEL_INDEX_WIDTH-1:0] index;

    always @(posedge clk) begin
        if (rst) begin
            index              <= {PIXEL_INDEX_WIDTH{1'b0}};
            sample_valid       <= 1'b0;
            frame_last         <= 1'b0;
            sample_pixel_index <= {PIXEL_INDEX_WIDTH{1'b0}};
            sample_pixel       <= 16'd0;
        end else begin
            sample_valid <= 1'b0;
            frame_last   <= 1'b0;

            if (sof) begin
                index <= {PIXEL_INDEX_WIDTH{1'b0}};
            end else if (sample_en && (index < FRAME_PIXELS)) begin
                sample_valid       <= 1'b1;
                sample_pixel_index <= index;
                sample_pixel       <= rgb565;
                frame_last         <= (index == FRAME_PIXELS - 1);
                index              <= index + 1'b1;
            end
        end
    end

    assign sample_frame_id      = meta_frame_id;
    assign sample_timestamp_ms  = meta_timestamp_ms;
    assign sample_config_version= meta_config_version;
    assign sample_event_seq     = meta_event_seq;
    assign sample_event_trigger = event_trigger;

endmodule
