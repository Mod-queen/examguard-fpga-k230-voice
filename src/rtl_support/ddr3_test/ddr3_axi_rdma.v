`timescale 1ns/1ps

// Multi-outstanding AXI4 read DMA. Original project design (backlog C11).
//
// The single-burst selftest engine measured only ~0.56 GB/s read because each
// burst waited for its own read latency. Here up to OUTSTANDING read bursts are
// issued with the SAME ID, so AXI guarantees in-order responses and no
// reordering buffer is needed; the read latency is hidden and throughput rises.
//
// Streams the read beats out (out_valid/out_data/out_last/out_ready).
module ddr3_axi_rdma #(
    parameter integer DATA_WIDTH  = 128,
    parameter integer ADDR_WIDTH  = 30,
    parameter integer ID_WIDTH    = 4,
    parameter integer BURST       = 16,
    parameter integer OUTSTANDING = 8
)(
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    start,          // one-cycle pulse
    input  wire [ADDR_WIDTH-1:0]   base_addr,
    input  wire [15:0]             burst_count,

    // AXI4 read address
    output wire [ID_WIDTH-1:0]     m_axi_arid,
    output wire [ADDR_WIDTH-1:0]   m_axi_araddr,
    output wire [7:0]              m_axi_arlen,
    output wire [2:0]              m_axi_arsize,
    output wire [1:0]              m_axi_arburst,
    output wire                    m_axi_arvalid,
    input  wire                    m_axi_arready,
    // AXI4 read data
    input  wire [ID_WIDTH-1:0]     m_axi_rid,
    input  wire [DATA_WIDTH-1:0]   m_axi_rdata,
    input  wire [1:0]              m_axi_rresp,
    input  wire                    m_axi_rlast,
    input  wire                    m_axi_rvalid,
    output wire                    m_axi_rready,

    // Streamed read data.
    output wire                    out_valid,
    output wire [DATA_WIDTH-1:0]   out_data,
    output wire                    out_last,
    input  wire                    out_ready,

    output reg                     busy,
    output reg                     done,
    output reg  [31:0]             beats_read,
    output reg  [31:0]             cycles
);
    localparam [2:0] AXI_SIZE = 3'd4;   // 16 bytes/beat
    localparam [1:0] AXI_INCR = 2'd1;
    localparam [15:0] BURST_STRIDE_LO = BURST * (DATA_WIDTH/8);

    reg [15:0] ar_sent, r_bursts_done;
    wire       outstanding_ok = (ar_sent - r_bursts_done) < OUTSTANDING[15:0];
    wire       more_bursts    = ar_sent < burst_count;

    assign m_axi_arid    = {ID_WIDTH{1'b0}};
    assign m_axi_arlen   = BURST[7:0] - 8'd1;
    assign m_axi_arsize  = AXI_SIZE;
    assign m_axi_arburst = AXI_INCR;
    assign m_axi_arvalid = busy && more_bursts && outstanding_ok;
    assign m_axi_araddr  = base_addr + (ar_sent * BURST_STRIDE_LO);

    assign out_valid   = m_axi_rvalid;
    assign out_data    = m_axi_rdata;
    assign out_last    = m_axi_rlast;
    assign m_axi_rready = out_ready;

    always @(posedge clk) begin
        if (rst) begin
            busy          <= 1'b0;
            done          <= 1'b0;
            ar_sent       <= 16'd0;
            r_bursts_done <= 16'd0;
            beats_read    <= 32'd0;
            cycles        <= 32'd0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                busy          <= 1'b1;
                ar_sent       <= 16'd0;
                r_bursts_done <= 16'd0;
                beats_read    <= 32'd0;
                cycles        <= 32'd0;
            end

            if (busy) begin
                if (cycles != 32'hffffffff) cycles <= cycles + 32'd1;
                if (m_axi_arvalid && m_axi_arready)            ar_sent <= ar_sent + 16'd1;
                if (m_axi_rvalid && m_axi_rready) begin
                    if (beats_read != 32'hffffffff) beats_read <= beats_read + 32'd1;
                    if (m_axi_rlast) r_bursts_done <= r_bursts_done + 16'd1;
                end
                if ((r_bursts_done == burst_count) && !m_axi_rvalid) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end
        end
    end
endmodule
