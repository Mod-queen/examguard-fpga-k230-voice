`timescale 1ns/1ps
// Bounded point-gap journal in UI domain. Records dropped sampled frames, not
// continuous missing-time intervals. Query results never prove full coverage.
// Eviction is explicit: unknown=1 when the query may intersect evicted gaps.
// Serialize query/append so the result is one stable journal snapshot.
module history_gap_journal #(
    parameter integer DEPTH=16,
    parameter integer PW=DEPTH<2 ? 1 : $clog2(DEPTH)
)(
    input wire clk,rst,
    input wire gap_valid,output wire gap_ready,
    input wire [95:0] gap_meta,input wire [7:0] gap_reason,
    input wire query_valid,output wire query_ready,
    input wire [63:0] query_lower,query_upper,
    output wire result_valid,input wire result_ready,
    output reg result_bad_range,result_unknown,
    output reg [31:0] result_count,
    output reg [95:0] result_first_meta,result_last_meta,
    output reg [7:0] result_first_reason,result_last_reason,
    output reg halted,
    output reg [31:0] recorded_count,evicted_count
);
    localparam IDLE=0,SCAN=1,RESULT=2;
    reg [1:0] state;
    reg [DEPTH-1:0] valid;
    reg [95:0] metadata[0:DEPTH-1];
    reg [7:0] reasons[0:DEPTH-1];
    reg [PW-1:0] write_ptr,scan_ptr;
    reg have_last,have_evicted;
    reg [63:0] last_time,evicted_through,lower,upper;
    assign gap_ready=!rst && !halted && state==IDLE;
    assign query_ready=!rst && state==IDLE && !(gap_valid && !halted);
    assign result_valid=!rst && state==RESULT;
    function [31:0] inc_sat;
        input [31:0] n;
        begin inc_sat=n==32'hffffffff ? n : n+1'b1;end
    endfunction
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;valid<=0;write_ptr<=0;scan_ptr<=0;have_last<=0;have_evicted<=0;
            last_time<=0;evicted_through<=0;lower<=0;upper<=0;halted<=0;
            recorded_count<=0;evicted_count<=0;result_bad_range<=0;result_unknown<=0;result_count<=0;
            result_first_meta<=0;result_last_meta<=0;result_first_reason<=0;result_last_reason<=0;
        end else case(state)
            IDLE:begin
                if(gap_valid && gap_ready) begin
                    if(have_last && gap_meta[63:0]<=last_time) halted<=1;
                    else begin
                        if(valid[write_ptr]) begin
                            have_evicted<=1;evicted_through<=metadata[write_ptr][63:0];
                            evicted_count<=inc_sat(evicted_count);
                        end
                        metadata[write_ptr]<=gap_meta;reasons[write_ptr]<=gap_reason;valid[write_ptr]<=1;
                        write_ptr<=write_ptr==DEPTH-1 ? 0 : write_ptr+1'b1;
                        have_last<=1;last_time<=gap_meta[63:0];recorded_count<=inc_sat(recorded_count);
                    end
                end else if(query_valid && query_ready) begin
                    lower<=query_lower;upper<=query_upper;scan_ptr<=0;
                    result_bad_range<=query_lower>query_upper;
                    result_unknown<=halted || (have_evicted && query_lower<=evicted_through);
                    result_count<=0;result_first_meta<=0;result_last_meta<=0;result_first_reason<=0;result_last_reason<=0;
                    state<=query_lower>query_upper ? RESULT : SCAN;
                end
            end
            SCAN:begin
                if(valid[scan_ptr] && metadata[scan_ptr][63:0]>=lower && metadata[scan_ptr][63:0]<=upper) begin
                    result_count<=result_count+1'b1;
                    if(result_count==0 || metadata[scan_ptr][63:0]<result_first_meta[63:0]) begin
                        result_first_meta<=metadata[scan_ptr];result_first_reason<=reasons[scan_ptr];
                    end
                    if(result_count==0 || metadata[scan_ptr][63:0]>result_last_meta[63:0]) begin
                        result_last_meta<=metadata[scan_ptr];result_last_reason<=reasons[scan_ptr];
                    end
                end
                if(scan_ptr==DEPTH-1) state<=RESULT;else scan_ptr<=scan_ptr+1'b1;
            end
            RESULT:if(result_ready) state<=IDLE;
            default:begin halted<=1;state<=IDLE;end
        endcase
    end
    // synthesis translate_off
    initial if(DEPTH<1) $fatal(1,"FAIL: history gap depth");
    // synthesis translate_on
endmodule
