`timescale 1ns/1ps
// Latest coherent source-domain snapshot. BOTH resets are the common transport
// barrier outputs; no independent reset of a toggle endpoint is supported.
// Each bus is atomic within its domain, NOT simultaneous across all domains.
module cdc_stats_snapshot #(parameter integer WIDTH=256)(
    input wire src_clk,src_rst,
    input wire [WIDTH-1:0] src_stats,
    input wire dst_clk,dst_rst,
    output reg [WIDTH-1:0] stats,
    output reg valid,
    output reg [31:0] age_cycles
);
    wire received;
    wire [WIDTH-1:0] received_data;
    cdc_event_transaction #(.DATA_WIDTH(WIDTH)) bridge(
        .src_clk(src_clk),.src_rst(src_rst),.src_valid(1'b1),.src_data(src_stats),.src_ready(),.src_accepted_count(),
        .dst_clk(dst_clk),.dst_rst(dst_rst),.dst_valid(received),.dst_data(received_data),.dst_ready(1'b1),.dst_delivered_count());
    always @(posedge dst_clk) begin
        if(dst_rst) begin stats<=0;valid<=0;age_cycles<=0;end
        else if(received) begin stats<=received_data;valid<=1;age_cycles<=0;end
        else if(valid && age_cycles!=32'hffffffff) age_cycles<=age_cycles+1'b1;
    end
endmodule
