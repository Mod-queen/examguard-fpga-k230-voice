`timescale 1ns/1ps

// Behavioral AXI4 read slave used only by the DMA testbench.
//
// Models a deep read pipeline: the first beat after the pipe drains costs
// LATENCY cycles; while more read addresses are already queued (more
// outstanding), beats stream back-to-back. So more outstanding requests hide
// the read latency, exactly what the multi-outstanding DMA is meant to exploit.
module axi_rd_slave_model #(
    parameter integer ADDR_WIDTH = 30,
    parameter integer DATA_WIDTH = 128,
    parameter integer ID_WIDTH   = 4,
    parameter integer BURST      = 16,
    parameter integer LATENCY    = 30,
    parameter integer QDEPTH     = 64
)(
    input  wire                  clk,
    input  wire                  rst,
    input  wire [ID_WIDTH-1:0]   arid,
    input  wire [ADDR_WIDTH-1:0] araddr,
    input  wire [7:0]            arlen,
    input  wire [2:0]            arsize,
    input  wire [1:0]            arburst,
    input  wire                  arvalid,
    output wire                  arready,
    output wire [ID_WIDTH-1:0]   rid,
    output wire [DATA_WIDTH-1:0] rdata,
    output wire [1:0]            rresp,
    output wire                  rlast,
    output wire                  rvalid,
    input  wire                  rready
);
    reg [ADDR_WIDTH-1:0] q [0:QDEPTH-1];
    reg [15:0] qhead, qtail, qcount;
    assign arready = (qcount < QDEPTH);

    wire enq = arvalid && arready;
    wire deq = !streaming && (qcount != 0);

    reg [ADDR_WIDTH-1:0] cur;
    reg [15:0] lat;
    reg [4:0]  beat;
    reg        streaming;

    function [127:0] data_of;
        input [29:0] a;
        input [4:0]  b;
        begin data_of = {94'b0, a, b[3:0]}; end
    endfunction

    assign rid    = {ID_WIDTH{1'b0}};
    assign rresp  = 2'b00;
    assign rdata  = data_of(cur[29:0], beat);
    assign rvalid = streaming && (lat == 0);
    assign rlast  = streaming && (lat == 0) && (beat == BURST-1);

    always @(posedge clk) begin
        if (rst) begin
            qhead <= 0; qtail <= 0; qcount <= 0;
            cur <= 0; lat <= 0; beat <= 0; streaming <= 0;
        end else begin
            if (enq) begin
                q[qtail] <= araddr;
                qtail    <= (qtail == QDEPTH-1) ? 16'd0 : qtail + 16'd1;
            end
            if (deq) begin
                cur       <= q[qhead];
                qhead     <= (qhead == QDEPTH-1) ? 16'd0 : qhead + 16'd1;
                lat       <= (qcount > 1) ? 16'd0 : LATENCY[15:0];
                beat      <= 5'd0;
                streaming <= 1'b1;
            end else if (streaming && lat != 0) begin
                lat <= lat - 16'd1;
            end else if (streaming && rvalid && rready) begin
                if (beat == BURST-1) streaming <= 1'b0;
                else beat <= beat + 5'd1;
            end
            qcount <= qcount + (enq ? 16'd1 : 16'd0) - (deq ? 16'd1 : 16'd0);
        end
    end
endmodule
