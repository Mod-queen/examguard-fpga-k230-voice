`timescale 1ns/1ps

// UI-domain bridge for the existing STANDARD (not FWFT) video FIFO IP.
// wrfifo_rd_en accepted on edge t produces dout after t; capture at t+1.
// One read in flight and one held stream beat; no extra read while stalled.
// Clear cancels local pending/held data and must accompany FIFO epoch reset.
// Hold clear while reset busy; reset busy alone also cancels held old data.
// This is NOT a CDC bridge: FIFO IP supplies CDC, with separate clock/reset
// constraints. Physical camera/display underflow/overflow observers belong
// in their clock domains and are not these UI-word counters.
module video_fifo_stream_bridge (
    input wire clk,rst,wr_clear,rd_clear,
    input wire wrfifo_empty,wrfifo_rst_busy,
    input wire [127:0] wrfifo_dout,
    output wire wrfifo_rd_en,
    output reg in_valid,
    output reg [127:0] in_data,
    input wire in_ready,
    input wire out_valid,
    input wire [127:0] out_data,
    output wire out_ready,
    input wire rdfifo_full,rdfifo_rst_busy,
    output wire rdfifo_wr_en,
    output wire [127:0] rdfifo_din,
    output reg [31:0] words_fetched,words_to_client,words_to_display,
    output reg [31:0] cancelled_words
);
    reg pending;
    wire cancel_write=wr_clear || wrfifo_rst_busy;
    assign wrfifo_rd_en=!rst && !cancel_write && !pending && !in_valid && !wrfifo_empty;
    assign out_ready=!rst && !rd_clear && !rdfifo_rst_busy && !rdfifo_full;
    assign rdfifo_wr_en=out_valid && out_ready;
    assign rdfifo_din=out_data;
    function [31:0] add_sat;
        input [31:0] a;
        input [1:0] b;
        reg [32:0] sum;
        begin sum={1'b0,a}+b;add_sat=sum[32] ? 32'hffffffff : sum[31:0];end
    endfunction
    always @(posedge clk) begin
        if(rst) begin
            pending<=0;in_valid<=0;in_data<=0;
            words_fetched<=0;words_to_client<=0;words_to_display<=0;cancelled_words<=0;
        end else begin
            if(cancel_write) begin
                // in_valid may have been visible before this edge; integrating
                // client must also gate in_ready on wr_clear/reset busy.
                cancelled_words<=add_sat(cancelled_words,{1'b0,pending}+{1'b0,in_valid});
                pending<=0;in_valid<=0;
            end else begin
                pending<=wrfifo_rd_en;
                if(wrfifo_rd_en) words_fetched<=add_sat(words_fetched,1);
                if(pending) begin in_data<=wrfifo_dout;in_valid<=1;end
                if(in_valid && in_ready) begin in_valid<=0;words_to_client<=add_sat(words_to_client,1);end
            end
            if(rdfifo_wr_en) words_to_display<=add_sat(words_to_display,1);
        end
    end
endmodule
