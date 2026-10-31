`timescale 1ns/1ps
// Store-forward per-source packet buffer -> round robin -> ONE physical UART.
// Ownership lasts through last byte acceptance. Gaps/stalls never preempt a
// packet. source_cancel discards only an INCOMPLETE capture, not a complete
// buffered/sending packet; reset cancels the whole UART/configuration epoch.
module uart_packet_mux #(
    parameter integer SOURCES=4,MAX_BYTES=384,CLK_FREQ_HZ=50000000,BAUD_RATE=115200,
    parameter integer OW=SOURCES<2 ? 1 : $clog2(SOURCES),
    parameter integer CW=$clog2(MAX_BYTES+1)
)(
    input wire clk,rst,
    input wire [SOURCES-1:0] in_valid,in_last,source_cancel,
    input wire [SOURCES*8-1:0] in_data,
    output wire [SOURCES-1:0] in_ready,
    output wire uart_txd,
    output reg protocol_fault,
    output reg [31:0] packets_sent,packets_dropped
);
    reg [CW-1:0] count[0:SOURCES-1],length[0:SOURCES-1];
    reg [SOURCES-1:0] full,discard;
    reg active;
    reg [OW-1:0] owner,next_owner;
    reg [CW-1:0] read_index;
    wire uart_busy;
    wire start=!rst && active && !uart_busy;
    wire [SOURCES*8-1:0] buffered_data;
    wire [7:0] data=buffered_data[owner*8 +: 8];
    uart_tx #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.BAUD_RATE(BAUD_RATE)) physical_uart(
        .clk(clk),.rst(rst),.tx_start(start),.tx_data(data),.tx(uart_txd),.busy(uart_busy));
    genvar s;
    generate for(s=0;s<SOURCES;s=s+1) begin: ready
        assign in_ready[s]=!rst && !full[s] && !source_cancel[s];
        // Physically separate one-write-port banks. A single array with a
        // procedural multi-source write loop prevents LUTRAM inference.
        (* ram_style="distributed" *) reg [7:0] memory[0:MAX_BYTES-1];
        always @(posedge clk) begin
            if(in_valid[s] && in_ready[s] && !discard[s]) memory[count[s]]<=in_data[s*8 +: 8];
        end
        assign buffered_data[s*8 +: 8]=memory[read_index];
    end endgenerate
    integer i,j,candidate,chosen,drops;
    always @* begin
        chosen=-1;
        for(j=0;j<SOURCES;j=j+1) begin
            candidate=next_owner+j;
            if(candidate>=SOURCES) candidate=candidate-SOURCES;
            if(chosen<0 && full[candidate]) chosen=candidate;
        end
    end
    function [31:0] inc_sat;
        input [31:0] n;
        begin inc_sat=n==32'hffffffff ? n : n+1'b1;end
    endfunction
    always @(posedge clk) begin
        if(rst) begin
            full<=0;discard<=0;active<=0;owner<=0;next_owner<=0;read_index<=0;
            protocol_fault<=0;packets_sent<=0;packets_dropped<=0;
            for(i=0;i<SOURCES;i=i+1) begin count[i]<=0;length[i]<=0;end
        end else begin
            drops=0;
            for(i=0;i<SOURCES;i=i+1) begin
                if(source_cancel[i] && !full[i]) begin
                    if(count[i]!=0 || discard[i]) drops=drops+1;
                    count[i]<=0;discard[i]<=0;
                end else if(in_valid[i] && in_ready[i]) begin
                    if(discard[i]) begin
                        if(in_last[i]) begin discard[i]<=0;count[i]<=0;drops=drops+1;end
                    end else begin
                        if(in_last[i]) begin full[i]<=1;length[i]<=count[i]+1'b1;count[i]<=0;end
                        else if(count[i]==MAX_BYTES-1) begin discard[i]<=1;protocol_fault<=1;end
                        else count[i]<=count[i]+1'b1;
                    end
                end
            end
            if(drops) begin
                if(32'hffffffff-packets_dropped<drops) packets_dropped<=32'hffffffff;
                else packets_dropped<=packets_dropped+drops;
            end
            if(!active && chosen>=0) begin active<=1;owner<=chosen;read_index<=0;end
            if(start) begin
                if(read_index==length[owner]-1) begin
                    full[owner]<=0;active<=0;read_index<=0;
                    next_owner<=owner==SOURCES-1 ? 0 : owner+1'b1;
                    packets_sent<=inc_sat(packets_sent);
                end else read_index<=read_index+1'b1;
            end
        end
    end
    // synthesis translate_off
    initial if(SOURCES<1 || MAX_BYTES<1) $fatal(1,"FAIL: uart packet mux parameters");
    // synthesis translate_on
endmodule
