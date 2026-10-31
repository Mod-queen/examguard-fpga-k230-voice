`timescale 1ns/1ps
// Holding one record until BOTH independent consumers have consumed it once.
// Source is a holding ready/valid queue, never FSM pulses. Common epoch reset
// cancels pending deliveries; already handed records retain their original ID.
module event_transaction_fork #(parameter integer WIDTH=256)(
    input wire clk,rst,
    input wire in_valid,
    input wire [WIDTH-1:0] in_data,
    output wire in_ready,
    output wire a_valid,b_valid,
    output wire [WIDTH-1:0] a_data,b_data,
    input wire a_ready,b_ready
);
    reg [WIDTH-1:0] held;
    reg a_pending,b_pending;
    assign in_ready=!rst && !a_pending && !b_pending;
    assign a_valid=!rst && a_pending;
    assign b_valid=!rst && b_pending;
    assign a_data=held;
    assign b_data=held;
    always @(posedge clk) begin
        if(rst) begin held<=0;a_pending<=0;b_pending<=0;end
        else begin
            if(a_valid && a_ready) a_pending<=0;
            if(b_valid && b_ready) b_pending<=0;
            if(in_valid && in_ready) begin held<=in_data;a_pending<=1;b_pending<=1;end
        end
    end
endmodule
