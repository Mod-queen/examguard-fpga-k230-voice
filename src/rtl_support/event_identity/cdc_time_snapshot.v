`timescale 1ns/1ps

// Coherent latest-snapshot time transfer, e.g. 50MHz identity time -> display.
// Reuses the SAME held-data handshake as events, continuously publishing the
// source time when the channel is free. Destination time is a recent SNAPSHOT,
// not the exact time of the current pixel edge; never advance it locally.
// consumer may latch {local_frame_id, time_ms} at SOF only when time_valid=1.
// age_cycles (saturating, destination cycles since last delivery) accompanies
// that snapshot so integrations can declare a stale/unknown timestamp honestly.
// Reset both domains together, with local synchronous release; no independent
// domain reset. Clock-domain physical constraints are those of bridge instance.
module cdc_time_snapshot(
    input wire src_clk,src_rst,
    input wire [63:0] src_time_ms,
    input wire dst_clk,dst_rst,
    output reg [63:0] time_ms,
    output reg time_valid,
    output reg [31:0] age_cycles
);
    wire transferred;
    wire [63:0] transferred_time;
    cdc_event_transaction #(.DATA_WIDTH(64)) bridge(
        .src_clk(src_clk),.src_rst(src_rst),.src_valid(1'b1),.src_data(src_time_ms),.src_ready(),.src_accepted_count(),
        .dst_clk(dst_clk),.dst_rst(dst_rst),.dst_valid(transferred),.dst_data(transferred_time),
        .dst_ready(1'b1),.dst_delivered_count());
    always @(posedge dst_clk) begin
        if(dst_rst) begin time_ms<=0;time_valid<=0;age_cycles<=0;end
        else if(transferred) begin time_ms<=transferred_time;time_valid<=1;age_cycles<=0;end
        else if(time_valid && age_cycles!=32'hffffffff) age_cycles<=age_cycles+1'b1;
    end
endmodule
