`timescale 1ns/1ps
// Whole-packet byte-stream mux for two sources feeding ONE UDP bridge.
// A is priority. A source is only advanced while its packet is selected; the
// unselected source holds its bytes/last. No interleaving inside a datagram.
module evidence_byte_mux(
    input wire clk,rst,
    input wire a_valid,a_last,input wire [7:0] a_data,output wire a_ready,
    input wire b_valid,b_last,input wire [7:0] b_data,output wire b_ready,
    output wire dst_valid,dst_last,output wire [7:0] dst_data,input wire dst_ready
);
    localparam IDLE=0,SA=1,SB=2;
    reg [1:0] sel;
    assign a_ready=!rst && sel==SA && dst_ready;
    assign b_ready=!rst && sel==SB && dst_ready;
    assign dst_valid=!rst && ((sel==SA && a_valid) || (sel==SB && b_valid));
    assign dst_last=sel==SA ? a_last : b_last;
    assign dst_data=sel==SA ? a_data : b_data;
    always @(posedge clk) begin
        if(rst) sel<=IDLE;
        else case(sel)
            // B (the small HR result packet in the history top) gets priority
            // so a continuous A pixel stream cannot starve the window verdict.
            IDLE:if(b_valid) sel<=SB;else if(a_valid) sel<=SA;
            SA:if(a_valid && a_ready && a_last) sel<=IDLE;
            SB:if(b_valid && b_ready && b_last) sel<=IDLE;
        endcase
    end
endmodule
