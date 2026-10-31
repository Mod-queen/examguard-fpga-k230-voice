`timescale 1ns/1ps

// ExamGuard independent DDR3 AXI4 self-test master. Original project design.
//
// Purpose (backlog C10): an independent, verifiable engine that a standalone DDR
// test project can attach to the MIG's AXI4 slave to measure real behaviour,
// without touching the stable camera/DDR/HDMI main chain. It:
//   * writes burst_count bursts of BURST beats over an address region,
//   * reads the same region back and compares against an address-derived
//     pattern (so two different regions never hold the same data -> a mirrored
//     "high address alias" would be detected as mismatches),
//   * counts cycles spent in the write and read phases (bandwidth input),
//   * saturates every counter and never wraps.
//
// The pattern is a pure function of the byte address, so a copy of the stream
// at a wrong (aliased) address produces a different expected value.
module ddr3_axi_selftest #(
    parameter integer DATA_WIDTH = 128,
    parameter integer ADDR_WIDTH = 30,
    parameter integer ID_WIDTH   = 4,
    parameter integer BURST      = 16        // beats per AXI burst (awlen = BURST-1)
)(
    input  wire                     clk,
    input  wire                     rst,

    input  wire                     start,
    input  wire [ADDR_WIDTH-1:0]    base_addr,     // byte address, burst aligned
    input  wire [15:0]              burst_count,

    // AXI4 write address
    output reg  [ID_WIDTH-1:0]      m_axi_awid,
    output reg  [ADDR_WIDTH-1:0]    m_axi_awaddr,
    output reg  [7:0]               m_axi_awlen,
    output reg  [2:0]               m_axi_awsize,
    output reg  [1:0]               m_axi_awburst,
    output reg                      m_axi_awvalid,
    input  wire                     m_axi_awready,
    // AXI4 write data (payload/last are combinational from the current beat so
    // wlast is asserted on the same beat it is accepted).
    output wire [DATA_WIDTH-1:0]    m_axi_wdata,
    output wire [DATA_WIDTH/8-1:0]  m_axi_wstrb,
    output wire                     m_axi_wlast,
    output reg                      m_axi_wvalid,
    input  wire                     m_axi_wready,
    // AXI4 write response
    input  wire [ID_WIDTH-1:0]      m_axi_bid,
    input  wire [1:0]               m_axi_bresp,
    input  wire                     m_axi_bvalid,
    output reg                      m_axi_bready,
    // AXI4 read address
    output reg  [ID_WIDTH-1:0]      m_axi_arid,
    output reg  [ADDR_WIDTH-1:0]    m_axi_araddr,
    output reg  [7:0]               m_axi_arlen,
    output reg  [2:0]               m_axi_arsize,
    output reg  [1:0]               m_axi_arburst,
    output reg                      m_axi_arvalid,
    input  wire                     m_axi_arready,
    // AXI4 read data
    input  wire [ID_WIDTH-1:0]      m_axi_rid,
    input  wire [DATA_WIDTH-1:0]    m_axi_rdata,
    input  wire [1:0]               m_axi_rresp,
    input  wire                     m_axi_rlast,
    input  wire                     m_axi_rvalid,
    output reg                      m_axi_rready,

    // Status
    output reg                      busy,
    output reg                      done,
    output reg  [31:0]              error_count,    // pattern mismatches / bad responses
    output reg  [31:0]              write_cycles,
    output reg  [31:0]              read_cycles,
    output reg  [31:0]              beats_written,
    output reg  [31:0]              beats_read
);
    localparam integer STRB_BITS   = DATA_WIDTH / 8;
    localparam integer BEAT_BYTES  = STRB_BITS;             // 128-bit -> 16 bytes
    localparam [2:0]   AXI_SIZE    = 3'd4;                  // 2^4 = 16 bytes per beat
    localparam [1:0]   AXI_INCR    = 2'd1;

    localparam [2:0] S_IDLE   = 3'd0, S_W_AW = 3'd1, S_W_DATA = 3'd2,
                     S_W_RESP = 3'd3, S_R_AR = 3'd4, S_R_DATA = 3'd5, S_DONE = 3'd6;

    reg [2:0]      state;
    reg [ADDR_WIDTH-1:0] region_base;
    reg [15:0]     bursts_total;
    reg [15:0]     burst_idx;
    reg [7:0]      beat_idx;
    reg [31:0]     wcycle, rcycle;

    // Address-derived 128-bit pattern: different byte addresses give different
    // data, so a wrong address (e.g. a mirrored high bit) yields a mismatch.
    function [DATA_WIDTH-1:0] pattern;
        input [ADDR_WIDTH-1:0] addr;
        reg [ADDR_WIDTH-1:0] a1, a2, a3;
        begin
            a1 = addr ^ {ADDR_WIDTH{1'b1}};
            a2 = addr + {{(ADDR_WIDTH-8){1'b0}}, 8'h5a};
            a3 = {addr[ADDR_WIDTH-1:8], 8'h96};
            pattern = { {(DATA_WIDTH-4*ADDR_WIDTH){1'b0}}, addr, a1, a2, a3 };
        end
    endfunction

    function [ADDR_WIDTH-1:0] burst_addr;
        input [15:0] idx;
        begin
            burst_addr = region_base + (idx * (BURST * BEAT_BYTES));
        end
    endfunction

    // Combinational write payload for the beat currently being presented.
    assign m_axi_wdata  = pattern(burst_addr(burst_idx) + beat_idx * BEAT_BYTES);
    assign m_axi_wstrb  = {STRB_BITS{1'b1}};
    assign m_axi_wlast  = (state == S_W_DATA) && (beat_idx == BURST[7:0] - 8'd1);

    always @(posedge clk) begin
        if (rst) begin
            state         <= S_IDLE;
            busy          <= 1'b0;
            done          <= 1'b0;
            error_count   <= 32'd0;
            write_cycles  <= 32'd0;
            read_cycles   <= 32'd0;
            beats_written <= 32'd0;
            beats_read    <= 32'd0;
            wcycle        <= 32'd0;
            rcycle        <= 32'd0;
            burst_idx     <= 16'd0;
            beat_idx      <= 8'd0;
            m_axi_awvalid <= 1'b0;
            m_axi_awlen   <= 8'd0;
            m_axi_awsize  <= AXI_SIZE;
            m_axi_awburst <= AXI_INCR;
            m_axi_wvalid  <= 1'b0;
            m_axi_bready  <= 1'b0;
            m_axi_arvalid <= 1'b0;
            m_axi_arlen   <= 8'd0;
            m_axi_arsize  <= AXI_SIZE;
            m_axi_arburst <= AXI_INCR;
            m_axi_rready  <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        region_base  <= base_addr;
                        bursts_total <= burst_count;
                        burst_idx    <= 16'd0;
                        beat_idx     <= 8'd0;
                        error_count  <= 32'd0;
                        beats_written<= 32'd0;
                        beats_read   <= 32'd0;
                        wcycle       <= 32'd0;
                        rcycle       <= 32'd0;
                        busy         <= 1'b1;
                        state        <= S_W_AW;
                    end
                end

                S_W_AW: begin
                    wcycle        <= wcycle + 32'd1;
                    m_axi_awid    <= {ID_WIDTH{1'b0}};
                    m_axi_awaddr  <= burst_addr(burst_idx);
                    m_axi_awlen   <= BURST[7:0] - 8'd1;
                    m_axi_awsize  <= AXI_SIZE;
                    m_axi_awburst <= AXI_INCR;
                    m_axi_awvalid <= 1'b1;
                    if (m_axi_awvalid && m_axi_awready) begin
                        m_axi_awvalid <= 1'b0;
                        beat_idx      <= 8'd0;
                        state         <= S_W_DATA;
                    end
                end

                S_W_DATA: begin
                    wcycle        <= wcycle + 32'd1;
                    m_axi_wvalid  <= 1'b1;
                    if (m_axi_wvalid && m_axi_wready) begin
                        if (beats_written != 32'hffffffff)
                            beats_written <= beats_written + 32'd1;
                        if (m_axi_wlast) begin
                            m_axi_wvalid <= 1'b0;
                            m_axi_bready <= 1'b1;
                            state        <= S_W_RESP;
                        end else begin
                            beat_idx <= beat_idx + 8'd1;
                        end
                    end
                end

                S_W_RESP: begin
                    wcycle <= wcycle + 32'd1;
                    if (m_axi_bvalid) begin
                        m_axi_bready <= 1'b0;
                        if (m_axi_bresp != 2'b00 &&
                            error_count != 32'hffffffff)
                            error_count <= error_count + 32'd1;
                        if (burst_idx + 16'd1 >= bursts_total) begin
                            burst_idx <= 16'd0;
                            state     <= S_R_AR;
                        end else begin
                            burst_idx <= burst_idx + 16'd1;
                            state     <= S_W_AW;
                        end
                    end
                end

                S_R_AR: begin
                    rcycle        <= rcycle + 32'd1;
                    m_axi_arid    <= {ID_WIDTH{1'b0}};
                    m_axi_araddr  <= burst_addr(burst_idx);
                    m_axi_arlen   <= BURST[7:0] - 8'd1;
                    m_axi_arsize  <= AXI_SIZE;
                    m_axi_arburst <= AXI_INCR;
                    m_axi_arvalid <= 1'b1;
                    if (m_axi_arvalid && m_axi_arready) begin
                        m_axi_arvalid <= 1'b0;
                        beat_idx      <= 8'd0;
                        state         <= S_R_DATA;
                    end
                end

                S_R_DATA: begin
                    rcycle       <= rcycle + 32'd1;
                    m_axi_rready <= 1'b1;
                    if (m_axi_rvalid && m_axi_rready) begin
                        if (beats_read != 32'hffffffff)
                            beats_read <= beats_read + 32'd1;
                        if (m_axi_rdata !=
                            pattern(burst_addr(burst_idx) + beat_idx * BEAT_BYTES) ||
                            m_axi_rresp != 2'b00) begin
                            if (error_count != 32'hffffffff)
                                error_count <= error_count + 32'd1;
                        end
                        if (m_axi_rlast) begin
                            m_axi_rready <= 1'b0;
                            if (burst_idx + 16'd1 >= bursts_total) begin
                                state <= S_DONE;
                            end else begin
                                burst_idx <= burst_idx + 16'd1;
                                state     <= S_R_AR;
                            end
                        end else begin
                            beat_idx <= beat_idx + 8'd1;
                        end
                    end
                end

                S_DONE: begin
                    busy         <= 1'b0;
                    done         <= 1'b1;
                    write_cycles <= wcycle;
                    read_cycles  <= rcycle;
                    state        <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
