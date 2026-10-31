`timescale 1ns/1ps
// Holding packet BYTE stream across asynchronous clocks. last travels in the
// same FIFO word as its byte; no pulse crosses alone. Not a store-forward packet
// buffer: destination UDP bridge buffers each datagram BEFORE starting Ethernet.
// Shared cancellation + local release BARRIER is REQUIRED outside this module.
module evidence_packet_cdc #(parameter integer DEPTH=256)(
    input wire src_clk,src_rst,src_valid,src_last,
    input wire [7:0] src_data,
    output wire src_ready,
    input wire dst_clk,dst_rst,dst_ready,
    output reg dst_valid,
    output reg [7:0] dst_data,
    output reg dst_last
);
    wire full,empty;
    wire [8:0] read_data;
    wire take=!dst_rst && !empty && (!dst_valid || dst_ready);
    assign src_ready=!src_rst && !full;
    async_fifo #(.DATA_WIDTH(9),.DEPTH(DEPTH)) fifo(
        .wclk(src_clk),.wrst_n(!src_rst),.winc(src_valid && src_ready),.wdata({src_last,src_data}),.wfull(full),
        .rclk(dst_clk),.rrst_n(!dst_rst),.rinc(take),.rdata(read_data),.rempty(empty));
    always @(posedge dst_clk) begin
        if(dst_rst) begin dst_valid<=0;dst_data<=0;dst_last<=0;end
        else if(!dst_valid || dst_ready) begin
            dst_valid<=take;
            if(take) {dst_last,dst_data}<=read_data;
        end
    end
endmodule
