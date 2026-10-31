`timescale 1ns/1ps
// UI-domain ordered decision consumer, not a camera/CDC decision producer.
// kind0 FRAME (pixels follow), kind1 DROP (no pixels), kind2 FENCE.
// One command in flight. Failed frames and source drops MUST be accepted by
// gap sink before any later command/fence proceeds. gap_ready means recorded,
// not merely observed. Sink, source queues, store and AXI share epoch reset.
module history_ordered_ingress(
    input wire clk,rst,
    input wire command_valid,output wire command_ready,
    input wire [1:0] command_kind,input wire [95:0] command_meta,
    input wire [7:0] command_reason,
    input wire source_valid,source_last,input wire [15:0] source_data,
    output wire source_ready,
    output wire frame_valid,input wire frame_ready,
    output wire frame_fence,output wire [95:0] frame_meta,
    output wire pixel_valid,pixel_last,output wire [15:0] pixel_data,
    input wire pixel_ready,
    input wire write_result_valid,output wire write_result_ready,
    input wire [95:0] write_result_meta,input wire [2:0] write_result_code,
    input wire fence_done,fence_ok,
    output wire gap_valid,input wire gap_ready,
    output wire [95:0] gap_meta,output reg [7:0] gap_reason,
    output wire result_valid,input wire result_ready,
    output reg [1:0] result_kind,output wire [95:0] result_meta,
    output reg [2:0] result_code,
    output reg halted,
    output reg [31:0] decisions_completed,gaps_recorded
);
    localparam IDLE=0,ISSUE=1,PIXELS=2,WAIT_RESULT=3,GAP=4,RESULT=5,WAIT_FENCE=6;
    reg [2:0] state;
    reg [95:0] meta;
    reg have_decision,have_fence;
    reg [63:0] last_decision,last_fence;
    wire [63:0] stamp=command_meta[63:0];
    wire decision_order=(!have_decision || stamp>last_decision) && (!have_fence || stamp>last_fence);
    wire fence_order=(!have_decision || stamp>=last_decision) && (!have_fence || stamp>=last_fence);
    assign command_ready=!rst && !halted && state==IDLE;
    assign frame_valid=!rst && !halted && state==ISSUE;
    assign frame_fence=result_kind==2;
    assign frame_meta=meta;
    assign pixel_valid=!rst && !halted && state==PIXELS && source_valid;
    assign pixel_last=source_last;
    assign pixel_data=source_data;
    assign source_ready=!rst && !halted && state==PIXELS && pixel_ready;
    assign write_result_ready=!rst && !halted && state==WAIT_RESULT;
    assign gap_valid=!rst && !halted && state==GAP;
    assign gap_meta=meta;
    assign result_valid=!rst && !halted && state==RESULT;
    assign result_meta=meta;
    function [31:0] inc_sat;
        input [31:0] n;
        begin inc_sat=n==32'hffffffff ? n : n+1'b1;end
    endfunction
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;meta<=0;result_kind<=0;result_code<=0;gap_reason<=0;halted<=0;
            have_decision<=0;have_fence<=0;last_decision<=0;last_fence<=0;
            decisions_completed<=0;gaps_recorded<=0;
        end else if(!halted) begin
            case(state)
                IDLE:if(command_valid && command_ready) begin
                    // Fail closed: reordered/unknown decisions cannot establish
                    // a truthful frontier. Recovery requires common reset.
                    if(command_kind==3 || (command_kind==2 ? !fence_order : !decision_order)) halted<=1;
                    else begin
                        meta<=command_meta;result_kind<=command_kind;result_code<=0;
                        if(command_kind!=2) begin have_decision<=1;last_decision<=stamp;end
                        if(command_kind==1) begin
                            // 0x80..FF reserved for source drop reasons, lower
                            // seven bits supplied by producer (never inferred).
                            gap_reason<={1'b1,command_reason[6:0]};state<=GAP;
                        end else state<=ISSUE;
                    end
                end
                ISSUE:if(frame_valid && frame_ready) state<=frame_fence ? WAIT_FENCE : PIXELS;
                PIXELS:if(source_valid && source_ready && source_last) state<=WAIT_RESULT;
                WAIT_RESULT:if(write_result_valid && write_result_ready) begin
                    if(write_result_meta!=meta || write_result_code>4) halted<=1;
                    else begin
                        result_code<=write_result_code;
                        if(write_result_code==0) state<=RESULT;
                        else begin gap_reason<={5'd0,write_result_code};state<=GAP;end
                    end
                end
                GAP:if(gap_valid && gap_ready) begin gaps_recorded<=inc_sat(gaps_recorded);state<=RESULT;end
                WAIT_FENCE:if(fence_done) begin
                    if(!fence_ok) halted<=1;
                    else begin have_fence<=1;last_fence<=meta[63:0];state<=RESULT;end
                end
                RESULT:if(result_valid && result_ready) begin
                    decisions_completed<=inc_sat(decisions_completed);state<=IDLE;
                end
                default:halted<=1;
            endcase
        end
    end
endmodule
