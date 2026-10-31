`timescale 1ns/1ps
// Orders a CLOSED, protected slot bitmap by source timestamp. Metadata query
// is combinational. A descriptor handshake is NOT a completed AXI read.
// Owner releases window only after done AND every downstream read/output drains.
module history_descriptor_reader #(
    parameter integer SLOTS=64,SW=SLOTS<2?1:$clog2(SLOTS)
)(
    input wire clk,rst,
    input wire start_valid, output wire start_ready,
    input wire [SLOTS-1:0] start_slots,
    input wire [255:0] start_event,
    output wire [SW-1:0] query_slot,
    input wire query_valid, input wire [95:0] query_meta,
    output wire out_valid, input wire out_ready,
    output reg [SW-1:0] out_slot,
    output reg [95:0] out_meta,
    output reg [255:0] out_event,
    output reg [31:0] out_index,
    output reg done,ok,
    output reg protocol_fault
);
    localparam IDLE=0,SCAN=1,EMIT=2;
    reg [1:0] state;
    reg [SLOTS-1:0] remaining;
    reg [SW-1:0] scan_slot,best_slot;
    reg [95:0] best_meta;
    reg found,have_previous;
    reg [63:0] previous_time;
    assign start_ready=!rst && state==IDLE;
    assign query_slot=scan_slot;
    assign out_valid=!rst && state==EMIT;
    wire candidate=remaining[scan_slot] && query_valid;
    wire better=candidate && (!found || query_meta[63:0]<best_meta[63:0]);
    wire invalid=remaining[scan_slot] && (!query_valid || (have_previous && query_meta[63:0]<=previous_time));
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;remaining<=0;scan_slot<=0;best_slot<=0;best_meta<=0;
            found<=0;have_previous<=0;previous_time<=0;
            out_slot<=0;out_meta<=0;out_event<=0;out_index<=0;done<=0;ok<=0;protocol_fault<=0;
        end else begin
            done<=0;
            case(state)
                IDLE: if(start_valid && start_ready) begin
                    remaining<=start_slots;out_event<=start_event;out_index<=0;
                    found<=0;have_previous<=0;scan_slot<=0;ok<=0;
                    if(start_slots==0) begin done<=1;ok<=0;end // empty != successful evidence
                    else state<=SCAN;
                end
                SCAN: begin
                    if(invalid) begin protocol_fault<=1;done<=1;ok<=0;state<=IDLE;end
                    else begin
                        if(better) begin best_slot<=scan_slot;best_meta<=query_meta;found<=1;end
                        if(scan_slot==SLOTS-1) begin
                            if(found || candidate) begin
                                out_slot<=better?scan_slot:best_slot;
                                out_meta<=better?query_meta:best_meta;
                                state<=EMIT;
                            end else begin done<=1;ok<=0;protocol_fault<=1;state<=IDLE;end
                        end else scan_slot<=scan_slot+1'b1;
                    end
                end
                EMIT: if(out_valid && out_ready) begin
                    remaining[out_slot]<=0;
                    previous_time<=out_meta[63:0];have_previous<=1;
                    if((remaining & ~({{(SLOTS-1){1'b0}},1'b1}<<out_slot))==0) begin done<=1;ok<=1;state<=IDLE;end
                    else begin
                        scan_slot<=0;found<=0;out_index<=out_index+1'b1;state<=SCAN;
                    end
                end
                default: begin state<=IDLE;done<=1;ok<=0;protocol_fault<=1;end
            endcase
        end
    end
    // synthesis translate_off
    initial if(SLOTS<1) $fatal(1,"FAIL: reader slot count");
    // synthesis translate_on
endmodule
