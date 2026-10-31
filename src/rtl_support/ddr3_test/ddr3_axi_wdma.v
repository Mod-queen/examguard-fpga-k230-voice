`timescale 1ns/1ps

// AXI4 write DMA. Original project design (C11). Streams burst_count bursts of
// BURST beats from an input stream into DDR. Writes are posted: the engine
// issues AW then streams W beats, then waits for the B response before the next
// burst. Pairs with ddr3_axi_rdma for the evidence-ring data path.
module ddr3_axi_wdma #(
    parameter integer DATA_WIDTH = 128,
    parameter integer ADDR_WIDTH = 30,
    parameter integer ID_WIDTH   = 4,
    parameter integer BURST      = 16
)(
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    start,
    input  wire [ADDR_WIDTH-1:0]   base_addr,
    input  wire [15:0]             burst_count,

    // Input data stream.
    input  wire                    in_valid,
    input  wire [DATA_WIDTH-1:0]   in_data,
    input  wire                    in_last,     // last beat of the whole transfer
    output wire                    in_ready,

    // AXI4 write address
    output reg  [ID_WIDTH-1:0]     m_axi_awid,
    output reg  [ADDR_WIDTH-1:0]   m_axi_awaddr,
    output reg  [7:0]              m_axi_awlen,
    output reg  [2:0]              m_axi_awsize,
    output reg  [1:0]              m_axi_awburst,
    output reg                     m_axi_awvalid,
    input  wire                    m_axi_awready,
    // AXI4 write data
    output wire [DATA_WIDTH-1:0]   m_axi_wdata,
    output wire [DATA_WIDTH/8-1:0] m_axi_wstrb,
    output wire                    m_axi_wlast,
    output reg                     m_axi_wvalid,
    input  wire                    m_axi_wready,
    // AXI4 write response
    input  wire [ID_WIDTH-1:0]     m_axi_bid,
    input  wire [1:0]              m_axi_bresp,
    input  wire                    m_axi_bvalid,
    output reg                     m_axi_bready,

    output reg                     busy,
    output reg                     done,
    output reg  [31:0]             beats_written,
    output reg  [31:0]             cycles,
    output reg  [31:0]             error_count
);
    localparam [2:0] AXI_SIZE = 3'd4;
    localparam [1:0] AXI_INCR = 2'd1;
    localparam [2:0] S_IDLE = 3'd0, S_AW = 3'd1, S_W = 3'd2, S_B = 3'd3, S_DONE = 3'd4;

    reg [2:0]  state;
    reg [15:0] burst_idx;
    reg [7:0]  beat_idx;

    assign m_axi_wdata = in_data;
    assign m_axi_wstrb = {(DATA_WIDTH/8){1'b1}};
    assign m_axi_wlast = (state == S_W) && (beat_idx == BURST[7:0] - 8'd1);
    assign in_ready    = (state == S_W) && m_axi_wready;

    always @(posedge clk) begin
        if (rst) begin
            state         <= S_IDLE;
            busy          <= 1'b0;
            done          <= 1'b0;
            burst_idx     <= 16'd0;
            beat_idx      <= 8'd0;
            beats_written <= 32'd0;
            cycles        <= 32'd0;
            error_count   <= 32'd0;
            m_axi_awvalid <= 1'b0;
            m_axi_wvalid  <= 1'b0;
            m_axi_bready  <= 1'b0;
            m_axi_awlen   <= 8'd0;
            m_axi_awsize  <= AXI_SIZE;
            m_axi_awburst <= AXI_INCR;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: if (start) begin
                    busy      <= 1'b1;
                    burst_idx <= 16'd0;
                    beat_idx  <= 8'd0;
                    beats_written <= 32'd0;
                    cycles    <= 32'd0;
                    error_count <= 32'd0;
                    state     <= S_AW;
                end

                S_AW: begin
                    cycles        <= cycles + 32'd1;
                    m_axi_awid    <= {ID_WIDTH{1'b0}};
                    m_axi_awaddr  <= base_addr + (burst_idx * (BURST * (DATA_WIDTH/8)));
                    m_axi_awlen   <= BURST[7:0] - 8'd1;
                    m_axi_awsize  <= AXI_SIZE;
                    m_axi_awburst <= AXI_INCR;
                    m_axi_awvalid <= 1'b1;
                    if (m_axi_awvalid && m_axi_awready) begin
                        m_axi_awvalid <= 1'b0;
                        beat_idx      <= 8'd0;
                        state         <= S_W;
                    end
                end

                S_W: begin
                    cycles       <= cycles + 32'd1;
                    m_axi_wvalid <= 1'b1;
                    if (in_valid && m_axi_wvalid && m_axi_wready) begin
                        if (beats_written != 32'hffffffff)
                            beats_written <= beats_written + 32'd1;
                        if (m_axi_wlast) begin
                            m_axi_wvalid <= 1'b0;
                            m_axi_bready <= 1'b1;
                            state        <= S_B;
                        end else begin
                            beat_idx <= beat_idx + 8'd1;
                        end
                    end
                end

                S_B: begin
                    cycles <= cycles + 32'd1;
                    if (m_axi_bvalid) begin
                        m_axi_bready <= 1'b0;
                        if (m_axi_bresp != 2'b00 && error_count != 32'hffffffff)
                            error_count <= error_count + 32'd1;
                        if (burst_idx + 16'd1 >= burst_count) begin
                            state <= S_DONE;
                        end else begin
                            burst_idx <= burst_idx + 16'd1;
                            state     <= S_AW;
                        end
                    end
                end

                S_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
