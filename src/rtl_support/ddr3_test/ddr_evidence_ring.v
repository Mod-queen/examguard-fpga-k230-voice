`timescale 1ns/1ps

// DDR seconds-level evidence ring controller. Original project design (C13).
//
// A producer streams frames (FRAME_PIXELS 16-bit words, pix_last ends a frame)
// which are written continuously into a ring of RING_FRAMES slots in DDR,
// overwriting the oldest. On event_pulse the controller keeps the PRE_FRAMES
// frames already in the ring and records POST_FRAMES more, then locks the
// window and streams it back out (out_valid/out_sof/out_last/out_ready). While
// a window is locked the producer is stalled so the evidence is never
// overwritten. A new event while busy is counted as overrun (queueing is C15).
//
// The DDR ports are simple word (16-bit) request/response so the control logic
// can be verified independently; a later AXI wrapper maps them to the MIG.
module ddr_evidence_ring #(
    parameter integer FRAME_PIXELS = 14400,   // 160x90
    parameter integer PRE_FRAMES   = 120,     // ~2 s at 60 fps
    parameter integer POST_FRAMES  = 120,
    parameter integer RING_FRAMES  = 512,
    parameter integer PIX_WIDTH    = 16,
    parameter integer SLOT_W = (RING_FRAMES < 2) ? 1 : $clog2(RING_FRAMES),
    parameter integer PIX_W  = (FRAME_PIXELS < 2) ? 1 : $clog2(FRAME_PIXELS),
    parameter integer ADDR_WIDTH = SLOT_W + PIX_W
)(
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    start,

    // Producer frame stream.
    input  wire                    pix_valid,
    input  wire [PIX_WIDTH-1:0]    pix_data,
    input  wire                    pix_last,
    output wire                    pix_ready,

    // Simple DDR word port, write.
    output reg                     wr_en,
    output reg  [ADDR_WIDTH-1:0]   wr_addr,
    output reg  [PIX_WIDTH-1:0]    wr_data,

    // Simple DDR word port, read (data valid one cycle after rd_en).
    output reg                     rd_en,
    output reg  [ADDR_WIDTH-1:0]   rd_addr,
    input  wire [PIX_WIDTH-1:0]    rd_data,
    input  wire                    rd_valid,

    input  wire                    event_pulse,

    // Locked-window readout stream.
    output reg                     out_valid,
    output reg  [PIX_WIDTH-1:0]    out_data,
    output reg                     out_sof,
    output reg                     out_last,
    input  wire                    out_ready,

    output reg                     window_ready,
    output reg                     busy,
    output reg                     overrun,
    output reg                     pending
);
    localparam [1:0] S_NORMAL = 2'd0, S_POST = 2'd1, S_READOUT = 2'd2;

    reg [1:0]  state;
    reg [SLOT_W-1:0] write_slot, window_start, rd_slot;
    reg [PIX_W-1:0]  pixel_in_frame, rd_pixel;
    reg [15:0] post_remaining;
    reg [15:0] window_frames;
    reg        rd_pending;

    function [SLOT_W-1:0] next_slot;
        input [SLOT_W-1:0] s;
        begin next_slot = (s == RING_FRAMES-1) ? {SLOT_W{1'b0}} : s + 1'b1; end
    endfunction

    function [SLOT_W-1:0] slot_minus;
        input [SLOT_W-1:0] s;
        input integer n;
        integer v;
        begin
            v = s - n;
            if (v < 0) v = v + RING_FRAMES;
            slot_minus = v[SLOT_W-1:0];
        end
    endfunction

    // Producer backpressure: only accept while capturing (never while locked).
    assign pix_ready = (state == S_NORMAL) || (state == S_POST);
    wire wr_fire = pix_valid && pix_ready;

    wire [SLOT_W-1:0] wr_slot_next = next_slot(write_slot);
    wire frame_done = wr_fire && (pixel_in_frame == FRAME_PIXELS-1);

    always @(posedge clk) begin
        if (rst) begin
            state           <= S_NORMAL;
            write_slot      <= {SLOT_W{1'b0}};
            window_start    <= {SLOT_W{1'b0}};
            rd_slot         <= {SLOT_W{1'b0}};
            pixel_in_frame  <= {PIX_W{1'b0}};
            rd_pixel        <= {PIX_W{1'b0}};
            post_remaining  <= 16'd0;
            window_frames   <= 16'd0;
            wr_en           <= 1'b0;
            wr_addr         <= {ADDR_WIDTH{1'b0}};
            wr_data         <= {PIX_WIDTH{1'b0}};
            rd_en           <= 1'b0;
            rd_addr         <= {ADDR_WIDTH{1'b0}};
            rd_pending      <= 1'b0;
            out_valid       <= 1'b0;
            out_data        <= {PIX_WIDTH{1'b0}};
            out_sof         <= 1'b0;
            out_last        <= 1'b0;
            window_ready    <= 1'b0;
            busy            <= 1'b0;
            overrun         <= 1'b0;
            pending         <= 1'b0;
        end else begin
            wr_en <= 1'b0;   // one-cycle write pulse

            // ---- producer write path ----
            if (wr_fire) begin
                wr_en   <= 1'b1;
                wr_addr <= (write_slot * FRAME_PIXELS) + pixel_in_frame;
                wr_data <= pix_data;
                if (pixel_in_frame == FRAME_PIXELS-1) begin
                    pixel_in_frame <= {PIX_W{1'b0}};
                    write_slot     <= wr_slot_next;
                    if (state == S_POST) begin
                        if (post_remaining <= 16'd1) begin
                            window_frames <= PRE_FRAMES + POST_FRAMES;
                            state         <= S_READOUT;
                            rd_slot       <= window_start;
                            rd_pixel      <= {PIX_W{1'b0}};
                            rd_pending    <= 1'b0;
                            window_ready  <= 1'b1;
                        end else begin
                            post_remaining <= post_remaining - 16'd1;
                        end
                    end
                end else begin
                    pixel_in_frame <= pixel_in_frame + 1'b1;
                end
            end

            // ---- event ----
            if (event_pulse) begin
                if ((state == S_NORMAL) && !window_ready) begin
                    window_start  <= slot_minus(write_slot, PRE_FRAMES);
                    post_remaining<= POST_FRAMES[15:0];
                    state         <= S_POST;
                    busy          <= 1'b1;
                end else begin
                    // Busy-time event: keep one pending, serve it after the
                    // current readout. overrun still records the overlap.
                    pending <= 1'b1;
                    overrun <= 1'b1;
                end
            end

            // ---- locked-window readout ----
            if (state == S_READOUT) begin
                if (!out_valid) begin
                    if (!rd_pending) begin
                        rd_en      <= 1'b1;
                        rd_addr    <= (rd_slot * FRAME_PIXELS) + rd_pixel;
                        rd_pending <= 1'b1;
                    end else if (rd_valid) begin
                        out_valid  <= 1'b1;
                        out_data   <= rd_data;
                        out_sof    <= (rd_pixel == {PIX_W{1'b0}});
                        out_last   <= (rd_pixel == FRAME_PIXELS-1);
                        rd_en      <= 1'b0;
                        rd_pending <= 1'b0;
                    end
                end else if (out_ready) begin
                    out_valid <= 1'b0;
                    if (rd_pixel == FRAME_PIXELS-1) begin
                        rd_pixel <= {PIX_W{1'b0}};
                        if (window_frames <= 16'd1) begin
                            window_ready <= 1'b0;
                            if (pending) begin
                                // Serve the queued event as the next window.
                                pending        <= 1'b0;
                                window_start   <= slot_minus(write_slot, PRE_FRAMES);
                                post_remaining <= POST_FRAMES[15:0];
                                state          <= S_POST;
                            end else begin
                                state <= S_NORMAL;
                                busy  <= 1'b0;
                            end
                        end else begin
                            window_frames <= window_frames - 16'd1;
                            rd_slot       <= next_slot(rd_slot);
                        end
                    end else begin
                        rd_pixel <= rd_pixel + 1'b1;
                    end
                end
            end
        end
    end
endmodule
