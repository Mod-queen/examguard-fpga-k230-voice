`timescale 1ns/1ps

// Independent evidence pipeline: stallable RGB565 source -> async FIFO ->
// frame DMA -> AXI ring -> locked-window readout. No main-video integration.
// event_pulse is in clk (MIG UI) domain. cap_rst and rst must be asserted
// together with AXI slave reset, and released synchronously in their domains.
// SOF/last and optional source metadata travel WITH pixels; after malformed
// frames seek the next SOF. Per-slot descriptors live in UI-domain RAM, NOT in
// DDR bytes, and publish only after successful B completion. Consumers must
// check commit_valid/window_done; a streamed pixel is not a final OK verdict.
// Real non-stallable camera needs a separate whole-frame drop policy (C14).
module ddr_evidence_axi #(
    parameter integer FRAME_PIXELS = 14400,
    parameter integer PRE_FRAMES = 2,
    parameter integer POST_FRAMES = 2,
    parameter integer RING_FRAMES = 8,
    parameter integer FIFO_DEPTH = 256,
    parameter integer BURST = 32,
    parameter integer ENABLE_META = 0,
    parameter integer META_WIDTH = 96,
    parameter [29:0] BASE_ADDR = 30'h10000000,
    parameter integer SLOT_W = (RING_FRAMES < 2) ? 1 : $clog2(RING_FRAMES)
)(
    input wire cap_clk, cap_rst,
    input wire pix_valid,
    input wire [15:0] pix_data,
    input wire pix_sof, pix_last,
    input wire [META_WIDTH-1:0] pix_meta,
    output wire pix_ready,
    output wire fifo_full,
    input wire clk, rst,
    input wire event_pulse,
    output wire event_ready,
    output reg window_started,
    output wire [31:0] window_frame_count,
    output wire out_valid,
    output wire [15:0] out_data,
    output wire out_sof, out_last,
    output wire [META_WIDTH-1:0] out_meta,
    output reg commit_valid,
    output reg [SLOT_W-1:0] commit_slot,
    output reg [META_WIDTH-1:0] commit_meta,
    input wire out_ready,
    output reg busy, pending, overrun,
    output reg window_done, window_ok,
    output reg [31:0] frames_committed, frames_failed, windows_completed,
    output reg [31:0] read_errors, rejected_events,
    output wire [31:0] write_beats, read_beats,
    output wire [3:0] m_axi_awid,
    output wire [29:0] m_axi_awaddr,
    output wire [7:0] m_axi_awlen,
    output wire [2:0] m_axi_awsize,
    output wire [1:0] m_axi_awburst,
    output wire m_axi_awvalid,
    input wire m_axi_awready,
    output wire [127:0] m_axi_wdata,
    output wire [15:0] m_axi_wstrb,
    output wire m_axi_wlast, m_axi_wvalid,
    input wire m_axi_wready,
    input wire [3:0] m_axi_bid,
    input wire [1:0] m_axi_bresp,
    input wire m_axi_bvalid,
    output wire m_axi_bready,
    output wire [3:0] m_axi_arid,
    output wire [29:0] m_axi_araddr,
    output wire [7:0] m_axi_arlen,
    output wire [2:0] m_axi_arsize,
    output wire [1:0] m_axi_arburst,
    output wire m_axi_arvalid,
    input wire m_axi_arready,
    input wire [3:0] m_axi_rid,
    input wire [127:0] m_axi_rdata,
    input wire [1:0] m_axi_rresp,
    input wire m_axi_rlast, m_axi_rvalid,
    output wire m_axi_rready
);
    localparam integer STRIDE = ((FRAME_PIXELS+7)/8)*16;
    localparam [1:0] C_IDLE=0, C_RUN=1, C_WAIT=2;
    reg [1:0] capture_state;
    reg [SLOT_W-1:0] write_slot, window_start, read_slot;
    reg [31:0] history, post_left, window_frames, read_left;
    reg reading, reader_active, window_error, frame_error;
    reg wr_start, rd_start;
    localparam integer META_BITS = ENABLE_META ? META_WIDTH : 1;
    wire [17+META_BITS:0] fifo_data;
    reg [META_BITS-1:0] capture_meta, read_meta;
    reg [META_BITS-1:0] slot_meta [0:RING_FRAMES-1];
    reg [RING_FRAMES-1:0] slot_valid;
    wire [META_BITS-1:0] fifo_meta = fifo_data[18 +: META_BITS];
    wire [META_BITS-1:0] ingress_meta;
    generate if (ENABLE_META) begin : metadata_enabled
        assign ingress_meta = pix_meta;
        assign out_meta = read_meta;
    end else begin : metadata_disabled
        assign ingress_meta = 0;
        assign out_meta = 0;
    end endgenerate
    assign event_ready = !rst && !busy;
    assign window_frame_count = window_frames;
    wire fifo_empty, fifo_pop;
    wire dma_in_ready, wr_busy, wr_done, wr_ok, rd_busy, rd_done, rd_ok;
    wire dma_valid = capture_state == C_RUN && !fifo_empty;
    wire [29:0] write_base = BASE_ADDR + write_slot*STRIDE;
    wire [29:0] read_base = BASE_ADDR + read_slot*STRIDE;

    // synthesis translate_off
    initial begin
        if (FRAME_PIXELS < 1 || META_WIDTH < 1 || PRE_FRAMES < 0 || POST_FRAMES < 1 ||
            PRE_FRAMES+POST_FRAMES < 1 || PRE_FRAMES+POST_FRAMES > RING_FRAMES ||
            FIFO_DEPTH < 4 || (FIFO_DEPTH & (FIFO_DEPTH-1)) != 0 ||
            BASE_ADDR[3:0] != 0 || {2'b00,BASE_ADDR}+RING_FRAMES*STRIDE > 32'h40000000)
            $fatal(1,"FAIL: invalid evidence AXI parameters");
    end
    // synthesis translate_on

    function [31:0] inc_sat;
        input [31:0] n;
        begin inc_sat = (n == 32'hffffffff) ? n : n+1'b1; end
    endfunction
    function [SLOT_W-1:0] next_slot;
        input [SLOT_W-1:0] s;
        begin next_slot = (s == RING_FRAMES-1) ? 0 : s+1'b1; end
    endfunction
    function [SLOT_W-1:0] subtract_slot;
        input [SLOT_W-1:0] s;
        input [31:0] n;
        integer v;
        begin
            v = s - n;
            if (v < 0) v = v + RING_FRAMES;
            subtract_slot = v;
        end
    endfunction
    wire commit_fire = capture_state == C_WAIT && wr_done && wr_ok && !frame_error;
    wire fail_fire = capture_state == C_WAIT && wr_done && (!wr_ok || frame_error);
    wire [31:0] history_now = fail_fire ? 0 :
        (commit_fire && history < RING_FRAMES ? history+1'b1 : history);
    wire [31:0] pre_now = history_now < PRE_FRAMES ? history_now : PRE_FRAMES;
    wire [SLOT_W-1:0] slot_now = commit_fire ? next_slot(write_slot) : write_slot;
    // A pending boolean deliberately preserves yesterday's degraded service:
    // re-anchor AFTER the old window, not at the original busy-time event.
    wire arm_event = (!busy && event_pulse) ||
        (busy && pending && !reading && post_left == 0 && window_frames == 0);
    assign pix_ready = !cap_rst && !fifo_full;
    assign fifo_pop = !rst && !fifo_empty &&
        ((capture_state == C_IDLE && !reading && !arm_event && !fifo_data[17]) ||
         (dma_valid && dma_in_ready));
    async_fifo #(.DATA_WIDTH(18+META_BITS), .DEPTH(FIFO_DEPTH)) ingress (
        .wclk(cap_clk), .wrst_n(!cap_rst), .winc(pix_valid && pix_ready),
        .wdata({ingress_meta,pix_sof,pix_last,pix_data}), .wfull(fifo_full),
        .rclk(clk), .rrst_n(!rst), .rinc(fifo_pop), .rdata(fifo_data), .rempty(fifo_empty));

    ddr3_axi_frame_dma #(.FRAME_PIXELS(FRAME_PIXELS), .BURST(BURST)) dma (
        .clk(clk), .rst(rst), .wr_start(wr_start), .wr_base(write_base),
        .in_valid(dma_valid), .in_data(fifo_data[15:0]), .in_last(fifo_data[16]),
        .in_ready(dma_in_ready), .wr_busy(wr_busy), .wr_done(wr_done), .wr_ok(wr_ok),
        .rd_start(rd_start), .rd_base(read_base),
        .out_valid(out_valid), .out_data(out_data), .out_sof(out_sof), .out_last(out_last),
        .out_ready(out_ready), .rd_busy(rd_busy), .rd_done(rd_done), .rd_ok(rd_ok),
        .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
        .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready),
        .write_beats(write_beats), .read_beats(read_beats));

    reg [31:0] capture_pixel;
    always @(posedge clk) begin
        if (rst) begin
            capture_state <= C_IDLE; capture_pixel <= 0; frame_error <= 0;
            write_slot <= 0; window_start <= 0; read_slot <= 0;
            history <= 0; post_left <= 0; window_frames <= 0; read_left <= 0;
            reading <= 0; reader_active <= 0; window_error <= 0;
            wr_start <= 0; rd_start <= 0; busy <= 0; pending <= 0; overrun <= 0;
            window_done <= 0; window_ok <= 0;
            frames_committed <= 0; frames_failed <= 0; windows_completed <= 0;
            read_errors <= 0; rejected_events <= 0;
            capture_meta <= 0; read_meta <= 0; slot_valid <= 0;
            commit_valid <= 0; commit_slot <= 0; commit_meta <= 0; window_started <= 0;
        end else begin
            wr_start <= 0; rd_start <= 0; window_done <= 0;
            commit_valid <= 0; window_started <= 0;
            case (capture_state)
                C_IDLE: if (!reading && !arm_event && !fifo_empty && fifo_data[17]) begin
                    wr_start <= 1; capture_state <= C_RUN; capture_pixel <= 0; frame_error <= 0;
                    capture_meta <= fifo_meta;
                    slot_valid[write_slot] <= 0; // overwritten slot is invalid BEFORE first AW
                end
                C_RUN: if (dma_valid && dma_in_ready) begin
                    if (fifo_data[17] != (capture_pixel == 0)) frame_error <= 1;
                    capture_pixel <= capture_pixel+1'b1;
                    if (fifo_data[16] || capture_pixel == FRAME_PIXELS-1) capture_state <= C_WAIT;
                end
                C_WAIT: if (wr_done) begin
                    capture_state <= C_IDLE;
                    if (commit_fire) begin
                        frames_committed <= inc_sat(frames_committed);
                        write_slot <= next_slot(write_slot);
                        history <= history_now;
                        slot_meta[write_slot] <= capture_meta;
                        slot_valid[write_slot] <= 1;
                        commit_valid <= 1; commit_slot <= write_slot;
                        if (ENABLE_META) commit_meta <= capture_meta;
                        else commit_meta <= 0;
                    end else begin
                        frames_failed <= inc_sat(frames_failed);
                        // No holes are presented as valid history. Restart a
                        // consecutive run; conservatively abort an active window.
                        history <= 0;
                        slot_valid <= 0;
                        if (busy && !reading) begin
                            window_done <= 1; window_ok <= 0; busy <= pending || event_pulse;
                            post_left <= 0; window_frames <= 0;
                        end
                    end
                end
                default: capture_state <= C_IDLE;
            endcase
            if (busy && !reading && commit_fire && post_left != 0) begin
                post_left <= post_left-1'b1;
                if (post_left == 1) begin
                    reading <= 1; read_slot <= window_start;
                    read_left <= window_frames; reader_active <= 0;
                end
            end
            if (arm_event) begin
                window_started <= 1;
                busy <= 1; pending <= 0; window_error <= 0; window_ok <= 0;
                window_start <= subtract_slot(slot_now, pre_now);
                post_left <= POST_FRAMES;
                window_frames <= pre_now+POST_FRAMES;
                if (POST_FRAMES == 0) begin
                    if (pre_now != 0) begin
                        reading <= 1; read_slot <= subtract_slot(slot_now, pre_now);
                        read_left <= pre_now; reader_active <= 0;
                    end else begin
                        window_done <= 1; window_ok <= 0; busy <= 0; window_frames <= 0;
                    end
                end
            end
            if (event_pulse && busy) begin
                overrun <= 1;
                if (pending && !arm_event) rejected_events <= inc_sat(rejected_events);
                pending <= 1;
            end
            if (reading) begin
                if (!reader_active) begin
                    rd_start <= 1; reader_active <= 1;
                    read_meta <= slot_meta[read_slot];
                    if (!slot_valid[read_slot]) window_error <= 1;
                end
                if (rd_done) begin
                    if (!rd_ok) begin
                        window_error <= 1; read_errors <= inc_sat(read_errors);
                    end
                    if (read_left == 1) begin
                        reading <= 0; window_done <= 1; window_ok <= !window_error && rd_ok;
                        windows_completed <= inc_sat(windows_completed);
                        window_frames <= 0; post_left <= 0;
                        // Include a same-cycle new event in pending service.
                        busy <= pending || event_pulse;
                    end else begin
                        read_left <= read_left-1'b1; read_slot <= next_slot(read_slot);
                        reader_active <= 0;
                    end
                end
            end
        end
    end
endmodule
