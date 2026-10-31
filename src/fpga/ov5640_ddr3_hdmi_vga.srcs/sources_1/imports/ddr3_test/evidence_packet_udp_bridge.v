`timescale 1ns/1ps
// SINGLE-CLOCK buffered datagram -> existing eth_udp_tx_gmii contract.
// Source and Ethernet must share clk/reset; this is NOT a UI->125MHz CDC.
// One packet owns memory through tx_done. No interleaving/byte-level arbitration.
module evidence_packet_udp_bridge #(parameter integer MAX_PACKET_BYTES=1108,
    parameter integer REQUIRE_TX_QUALIFIED=0)(
    input wire clk,rst,
    input wire tx_qualified, // synchronous to clk; ignored by legacy default
    input wire in_valid,in_last,
    input wire [7:0] in_data,
    output wire in_ready,
    output wire tx_en_pulse,
    output wire [15:0] data_length,
    input wire payload_req,tx_done,
    output wire [7:0] payload_data,
    output reg protocol_fault,
    output reg [31:0] packets_sent,packets_dropped
);
    localparam integer AW=$clog2(MAX_PACKET_BYTES+1);
    localparam [1:0] CAPTURE=0,START=1,SEND=2,DISCARD=3;
    reg [1:0] state;
    (* ram_style="distributed" *) reg [7:0] bytes[0:MAX_PACKET_BYTES-1];
    reg [AW-1:0] count,read_count,length;
    wire allowed=(REQUIRE_TX_QUALIFIED==0) || tx_qualified;
    function [31:0] inc_sat;
        input [31:0] n;
        begin inc_sat=n==32'hffffffff ? n : n+1'b1;end
    endfunction
    assign in_ready=!rst && (state==CAPTURE || state==DISCARD);
    assign tx_en_pulse=!rst && allowed && state==START;
    assign data_length=length;
    assign payload_data=read_count<length ? bytes[read_count] : 8'd0;
    always @(posedge clk) begin
        if(rst) begin
            state<=CAPTURE;count<=0;read_count<=0;length<=0;
            protocol_fault<=0;packets_sent<=0;packets_dropped<=0;
        end else case(state)
            CAPTURE:if(!allowed && (count!=0 || in_valid)) begin
                // Poison this entire datagram. Recovery cannot transmit its tail.
                if(in_valid && in_last) begin
                    packets_dropped<=inc_sat(packets_dropped);count<=0;
                end else state<=DISCARD;
            end else if(in_valid && in_ready) begin
                bytes[count]<=in_data;
                if(in_last) begin length<=count+1'b1;read_count<=0;state<=START;end
                else if(count==MAX_PACKET_BYTES-1) begin
                    protocol_fault<=1;state<=DISCARD;
                end else count<=count+1'b1;
            end
            START:if(!allowed) begin
                packets_dropped<=inc_sat(packets_dropped);count<=0;state<=CAPTURE;
            end else state<=SEND;
            SEND:begin
                // Caller resets ONLY the Ethernet MAC while unqualified.
                // The packet FIFO/AXI/video and these counters keep running.
                if(!allowed) begin
                    packets_dropped<=inc_sat(packets_dropped);count<=0;state<=CAPTURE;
                end else begin
                if(payload_req) begin
                    if(read_count<length) read_count<=read_count+1'b1;
                    else protocol_fault<=1;
                end
                if(tx_done) begin
                    if(read_count+(payload_req && read_count<length)!=length) protocol_fault<=1;
                    packets_sent<=inc_sat(packets_sent);count<=0;state<=CAPTURE;
                end
                end
            end
            DISCARD:if(in_valid && in_last) begin
                packets_dropped<=inc_sat(packets_dropped);count<=0;state<=CAPTURE;
            end
        endcase
    end
    // synthesis translate_off
    initial if(MAX_PACKET_BYTES<1 || MAX_PACKET_BYTES>1472)
        $fatal(1,"FAIL: UDP packet buffer must fit standard Ethernet MTU");
    // synthesis translate_on
endmodule
