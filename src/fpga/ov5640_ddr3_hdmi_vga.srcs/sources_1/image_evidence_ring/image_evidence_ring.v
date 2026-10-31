`timescale 1ns/1ps

// Parameterized low-resolution image evidence ring.
//
// A frame is written pixel by pixel into the current ring slot.  The slot is
// committed only on frame_last, so an event trigger always refers to a whole
// frame and its metadata.  The video/DDR display path is deliberately outside
// this module; a future downsampler or independent DDR writer can feed the
// same interface.
module image_evidence_ring #(
    parameter integer FRAME_WIDTH       = 320,
    parameter integer FRAME_HEIGHT      = 180,
    parameter integer PIXEL_WIDTH       = 8,
    parameter integer PRE_FRAMES        = 8,
    parameter integer POST_FRAMES       = 8,
    parameter integer RING_DEPTH        = 32,
    parameter integer PIXEL_INDEX_WIDTH =
        ((FRAME_WIDTH * FRAME_HEIGHT) < 2) ? 1 :
        $clog2(FRAME_WIDTH * FRAME_HEIGHT),
    parameter integer FRAME_INDEX_WIDTH =
        ((PRE_FRAMES + POST_FRAMES + 1) < 2) ? 1 :
        $clog2(PRE_FRAMES + POST_FRAMES + 1),
    parameter integer SLOT_INDEX_WIDTH  =
        ((RING_DEPTH) < 2) ? 1 : $clog2(RING_DEPTH)
) (
    input                             clk,
    input                             rst,

    // Frame writer. sample_pixel_index is row-major, 0 through PIXELS-1.
    input                             sample_valid,
    input                             frame_last,
    input  [PIXEL_INDEX_WIDTH-1:0]    sample_pixel_index,
    input  [PIXEL_WIDTH-1:0]          sample_pixel,
    input  [31:0]                     sample_frame_id,
    input  [31:0]                     sample_timestamp_ms,
    input  [7:0]                      sample_config_version,
    input  [7:0]                      sample_event_seq,
    input                             event_trigger,

    // The consumer holds this high for the complete readout transaction.
    input                             readout_active,
    output reg                        frame_busy,
    output reg                        frame_done,
    output reg                        frame_available,
    output reg                        image_evidence_overrun,
    output reg [7:0]                  snapshot_event_seq,

    // Synchronous read port. Data and metadata are valid one clock after req.
    input                             read_req,
    input  [FRAME_INDEX_WIDTH-1:0]    read_frame_index,
    input  [PIXEL_INDEX_WIDTH-1:0]    read_pixel_index,
    output reg                        read_valid,
    output reg [PIXEL_WIDTH-1:0]      read_pixel,
    output reg [31:0]                 read_frame_id,
    output reg [31:0]                 read_timestamp_ms,
    output reg [7:0]                  read_config_version
);

    localparam integer FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;
    localparam integer WINDOW_LENGTH = PRE_FRAMES + POST_FRAMES + 1;

    reg [PIXEL_WIDTH-1:0] frame_mem [0:RING_DEPTH * FRAME_PIXELS - 1];
    reg [31:0] frame_id_mem [0:RING_DEPTH-1];
    reg [31:0] timestamp_mem [0:RING_DEPTH-1];
    reg [7:0] config_mem [0:RING_DEPTH-1];

    reg [SLOT_INDEX_WIDTH-1:0] write_slot;
    reg [SLOT_INDEX_WIDTH-1:0] snapshot_base;
    reg [FRAME_INDEX_WIDTH-1:0] post_remaining;

    function [SLOT_INDEX_WIDTH-1:0] next_slot;
        input [SLOT_INDEX_WIDTH-1:0] slot;
        begin
            if (slot == RING_DEPTH - 1)
                next_slot = {SLOT_INDEX_WIDTH{1'b0}};
            else
                next_slot = slot + 1'b1;
        end
    endfunction

    function [SLOT_INDEX_WIDTH-1:0] slot_before;
        input [SLOT_INDEX_WIDTH-1:0] slot;
        integer slot_value;
        begin
            if (slot >= PRE_FRAMES)
                slot_value = slot - PRE_FRAMES;
            else
                slot_value = RING_DEPTH + slot - PRE_FRAMES;
            slot_before = slot_value[SLOT_INDEX_WIDTH-1:0];
        end
    endfunction

    function [SLOT_INDEX_WIDTH-1:0] slot_at;
        input [SLOT_INDEX_WIDTH-1:0] base;
        input [FRAME_INDEX_WIDTH-1:0] offset;
        integer slot_value;
        begin
            slot_value = base + offset;
            if (slot_value >= RING_DEPTH)
                slot_value = slot_value - RING_DEPTH;
            slot_at = slot_value[SLOT_INDEX_WIDTH-1:0];
        end
    endfunction

    wire [SLOT_INDEX_WIDTH-1:0] read_slot =
        slot_at(snapshot_base, read_frame_index);

    always @(posedge clk) begin
        if (rst) begin
            write_slot             <= {SLOT_INDEX_WIDTH{1'b0}};
            snapshot_base          <= {SLOT_INDEX_WIDTH{1'b0}};
            post_remaining         <= {FRAME_INDEX_WIDTH{1'b0}};
            frame_busy             <= 1'b0;
            frame_done             <= 1'b0;
            frame_available        <= 1'b0;
            image_evidence_overrun <= 1'b0;
            snapshot_event_seq     <= 8'd0;
            read_valid             <= 1'b0;
            read_pixel             <= {PIXEL_WIDTH{1'b0}};
            read_frame_id          <= 32'd0;
            read_timestamp_ms      <= 32'd0;
            read_config_version    <= 8'd0;
        end else begin
            frame_done <= 1'b0;
            read_valid <= 1'b0;

            if (sample_valid && (sample_pixel_index < FRAME_PIXELS))
                frame_mem[write_slot * FRAME_PIXELS + sample_pixel_index] <=
                    sample_pixel;

            if (sample_valid && frame_last) begin
                frame_id_mem[write_slot]  <= sample_frame_id;
                timestamp_mem[write_slot] <= sample_timestamp_ms;
                config_mem[write_slot]    <= sample_config_version;

                // A trigger is accepted once, at the end of its frame. The
                // current frame is part of the window, followed by POST_FRAMES.
                if (event_trigger && !frame_busy && !frame_available &&
                    !readout_active) begin
                    snapshot_base      <= slot_before(write_slot);
                    snapshot_event_seq <= sample_event_seq;
                    if (POST_FRAMES == 0) begin
                        frame_done      <= 1'b1;
                        frame_available <= 1'b1;
                        frame_busy      <= 1'b0;
                    end else begin
                        frame_busy      <= 1'b1;
                        post_remaining <= POST_FRAMES;
                    end
                end else if (event_trigger) begin
                    // The original window remains authoritative; the host can
                    // report this flag instead of silently losing an event.
                    image_evidence_overrun <= 1'b1;
                end

                if (frame_busy) begin
                    if (post_remaining <= 1) begin
                        post_remaining  <= {FRAME_INDEX_WIDTH{1'b0}};
                        frame_busy      <= 1'b0;
                        frame_done      <= 1'b1;
                        frame_available <= 1'b1;
                    end else begin
                        post_remaining <= post_remaining - 1'b1;
                    end
                end

                write_slot <= next_slot(write_slot);
            end

            // Once a consumer starts, the completed window is owned by it.
            // New triggers are rejected until readout_active is released.
            if (readout_active && frame_available)
                frame_available <= 1'b0;

            if (read_req && (frame_available || readout_active) &&
                (read_frame_index < WINDOW_LENGTH) &&
                (read_pixel_index < FRAME_PIXELS)) begin
                read_pixel          <= frame_mem[read_slot * FRAME_PIXELS +
                                                read_pixel_index];
                read_frame_id       <= frame_id_mem[read_slot];
                read_timestamp_ms   <= timestamp_mem[read_slot];
                read_config_version <= config_mem[read_slot];
                read_valid          <= 1'b1;
            end
        end
    end

endmodule
