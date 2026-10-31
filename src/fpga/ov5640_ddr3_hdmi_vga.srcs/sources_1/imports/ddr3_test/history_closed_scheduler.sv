`timescale 1ns/1ps
// Automatic closed-window scheduler for the history data plane.
// Accepted (window,token,event) handles are kept in a bounded in-order FIFO.
// A monotonic ordered fence advances the directory seal. Once the directory
// reports the head window CLOSED, this module queries the bounded point-gap
// journal, then issues the reader command, and finally merges the gap summary
// with the reader result. The merged result is held until consumed.
// Point-gap count/unknown is NOT a continuous-coverage proof. reset must cancel
// the whole store, journal, producer and AXI together.
module history_closed_scheduler #(
    parameter integer WINDOWS=4,
    parameter integer GAP_DEPTH=16,
    parameter [63:0] PRE_MS=2000,
    parameter [63:0] POST_MS=2000,
    parameter integer GW=WINDOWS<2 ? 1 : $clog2(WINDOWS)
)(
    input wire clk,rst,
    // accepted handle (caller holds request_event through the accept edge)
    output wire request_ready,input wire [255:0] request_event,
    input wire accepted,input wire [GW-1:0] accepted_window,input wire [31:0] accepted_token,
    // ordered fence source
    input wire fence_valid,input wire [63:0] fence_time,
    // directory status / seal command
    input wire directory_writer_pending,
    input wire [WINDOWS-1:0] directory_closed_mask,
    output wire seal_valid,input wire seal_ready,output wire [63:0] seal_time,
    // reader command/result
    output wire read_valid,input wire read_ready,
    output wire [GW-1:0] read_window,output wire [31:0] read_token,
    input wire s_result_valid,output wire s_result_ready,
    input wire [2:0] s_result_code,input wire s_result_ok,
    input wire s_result_truncated,s_result_capture_error,
    input wire [31:0] s_result_frames,s_result_token,
    input wire [GW-1:0] s_result_window,
    // point-gap append/query side
    input wire gap_valid,output wire gap_ready,
    input wire [95:0] gap_meta,input wire [7:0] gap_reason,
    // merged result
    output wire result_valid,input wire result_ready,
    output wire [GW-1:0] result_window,output wire [31:0] result_token,
    output wire [2:0] result_code,
    output wire result_ok,result_truncated,result_capture_error,
    output wire [31:0] result_frames,
    output wire [31:0] result_gap_count,
    output wire result_gap_unknown,result_gap_bad_range,
    output wire result_coverage_ok,
    output wire [63:0] result_lower,result_upper,
    output wire [95:0] result_gap_first_meta,result_gap_last_meta,
    output wire [7:0] result_gap_first_reason,result_gap_last_reason,
    output wire [255:0] result_event,
    // status
    input wire [2:0] store_faults,
    output reg halted,protocol_fault,
    output wire [GW:0] pending_windows,
    output reg [63:0] sealed_time,
    output wire [31:0] gap_recorded_count,gap_evicted_count,
    output wire journal_halted_o
);
    localparam IDLE=0,GAPQ=1,GAPW=2,READ=3,RESULT=4,WAIT_DONE=5;
    reg [2:0] state;
    reg [GW:0] count;
    reg [GW-1:0] head,tail;
    reg [GW-1:0] h_window[0:WINDOWS-1];
    reg [31:0] h_token[0:WINDOWS-1];
    reg [255:0] h_event[0:WINDOWS-1];
    reg [63:0] h_lower[0:WINDOWS-1],h_upper[0:WINDOWS-1];
    reg [63:0] seal_target;
    reg seal_target_valid;
    reg [31:0] gap_count_l;
    reg gap_unknown_l,gap_bad_range_l;
    reg [95:0] gap_first_l,gap_last_l;
    reg [7:0] gap_first_reason_l,gap_last_reason_l;
    integer k;
    wire [63:0] event_time=request_event[95:32];
    wire [63:0] next_lower_w=event_time<PRE_MS?64'd0:event_time-PRE_MS;
    wire [63:0] next_upper_w=(64'hffffffffffffffff-event_time<POST_MS)?64'hffffffffffffffff:event_time+POST_MS;
    function [GW-1:0] advance(input [GW-1:0] p);
        begin advance=p==WINDOWS-1 ? 0 : p+1'b1;end
    endfunction
    // Integrated bounded point-gap journal.
    wire journal_halted,journal_query_ready,journal_result_valid;
    wire journal_result_bad_range,journal_result_unknown;
    wire [31:0] journal_result_count,journal_recorded,journal_evicted;
    wire [95:0] journal_result_first,journal_result_last;
    wire [7:0] journal_result_first_reason,journal_result_last_reason;
    wire journal_query_valid=!rst && !halted && state==GAPQ;
    wire [63:0] journal_query_lower=h_lower[head];
    wire [63:0] journal_query_upper=h_upper[head];
    wire journal_result_ready=!rst && !halted && state==GAPW;
    history_gap_journal #(.DEPTH(GAP_DEPTH)) journal(
        .clk(clk),.rst(rst),
        .gap_valid(gap_valid),.gap_ready(gap_ready),.gap_meta(gap_meta),.gap_reason(gap_reason),
        .query_valid(journal_query_valid),.query_ready(journal_query_ready),
        .query_lower(journal_query_lower),.query_upper(journal_query_upper),
        .result_valid(journal_result_valid),.result_ready(journal_result_ready),
        .result_bad_range(journal_result_bad_range),.result_unknown(journal_result_unknown),
        .result_count(journal_result_count),.result_first_meta(journal_result_first),
        .result_last_meta(journal_result_last),.result_first_reason(journal_result_first_reason),
        .result_last_reason(journal_result_last_reason),.halted(journal_halted),
        .recorded_count(journal_recorded),.evicted_count(journal_evicted));
    assign request_ready=!rst && !halted && count!=WINDOWS;
    assign seal_valid=!rst && !halted && seal_target_valid && !directory_writer_pending && seal_ready;
    assign seal_time=seal_target;
    assign read_valid=!rst && !halted && state==READ;
    assign read_window=h_window[head];
    assign read_token=h_token[head];
    assign s_result_ready=!rst && !halted && state==RESULT && s_result_valid && result_ready;
    assign result_valid=!rst && !halted && state==RESULT && s_result_valid;
    assign result_window=s_result_window;
    assign result_token=s_result_token;
    assign result_code=s_result_code;
    assign result_ok=s_result_ok;
    assign result_truncated=s_result_truncated;
    assign result_capture_error=s_result_capture_error;
    assign result_frames=s_result_frames;
    assign result_gap_count=gap_count_l;
    assign result_gap_unknown=gap_unknown_l;
    assign result_gap_bad_range=gap_bad_range_l;
    assign result_coverage_ok=s_result_ok && !gap_unknown_l && !gap_bad_range_l && gap_count_l==0;
    assign result_lower=h_lower[head];
    assign result_upper=h_upper[head];
    assign result_gap_first_meta=gap_first_l;
    assign result_gap_last_meta=gap_last_l;
    assign result_gap_first_reason=gap_first_reason_l;
    assign result_gap_last_reason=gap_last_reason_l;
    assign result_event=h_event[head];
    assign pending_windows=count;
    assign gap_recorded_count=journal_recorded;
    assign gap_evicted_count=journal_evicted;
    assign journal_halted_o=journal_halted;
    wire push_ok=accepted && !rst && !halted && count!=WINDOWS;
    wire push_bad=accepted && !rst && !halted && count==WINDOWS;
    wire pop=!rst && !halted && state==WAIT_DONE && read_ready;
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;count<=0;head<=0;tail<=0;
            seal_target<=0;seal_target_valid<=0;sealed_time<=0;
            gap_count_l<=0;gap_unknown_l<=0;gap_bad_range_l<=0;
            gap_first_l<=0;gap_last_l<=0;gap_first_reason_l<=0;gap_last_reason_l<=0;
            halted<=0;protocol_fault<=0;
            for(k=0;k<WINDOWS;k=k+1) begin
                h_window[k]<=0;h_token[k]<=0;h_event[k]<=0;h_lower[k]<=0;h_upper[k]<=0;
            end
        end else if(!halted) begin
            if(push_ok) begin
                h_window[tail]<=accepted_window;
                h_token[tail]<=accepted_token;
                h_event[tail]<=request_event;
                h_lower[tail]<=next_lower_w;
                h_upper[tail]<=next_upper_w;
                tail<=advance(tail);
            end
            if(push_bad) begin halted<=1;protocol_fault<=1;end
            if(fence_valid) begin
                if(fence_time<sealed_time || (seal_target_valid && fence_time<seal_target)) begin
                    halted<=1;protocol_fault<=1;
                end else begin
                    seal_target<=fence_time;seal_target_valid<=1;
                end
            end
            if(seal_valid && seal_ready) begin
                sealed_time<=seal_target;
                // A fence accepted in this same cycle becomes the next target.
                if(!(fence_valid && fence_time>=sealed_time &&
                     (!seal_target_valid || fence_time>=seal_target)))
                    seal_target_valid<=0;
            end
            if(journal_halted) begin halted<=1;protocol_fault<=1;end
            if(store_faults!=0) begin halted<=1;protocol_fault<=1;end
            case(state)
                IDLE:if(count!=0 && directory_closed_mask[h_window[head]]) state<=GAPQ;
                GAPQ:if(journal_query_valid && journal_query_ready) state<=GAPW;
                GAPW:if(journal_result_valid && journal_result_ready) begin
                    gap_count_l<=journal_result_count;
                    gap_unknown_l<=journal_result_unknown;
                    gap_bad_range_l<=journal_result_bad_range;
                    gap_first_l<=journal_result_first;
                    gap_last_l<=journal_result_last;
                    gap_first_reason_l<=journal_result_first_reason;
                    gap_last_reason_l<=journal_result_last_reason;
                    if(journal_result_bad_range) begin
                        halted<=1;protocol_fault<=1;
                    end
                    state<=READ;
                end
                READ:if(read_ready) state<=RESULT;
                RESULT:if(result_valid && result_ready) state<=WAIT_DONE;
                WAIT_DONE:if(read_ready) begin
                    head<=advance(head);state<=IDLE;
                end
                default:begin halted<=1;protocol_fault<=1;state<=IDLE;end
            endcase
            count<=count+{{GW{1'b0}},push_ok}-{{GW{1'b0}},pop};
        end
    end
    // synthesis translate_off
    initial if(WINDOWS<1 || GAP_DEPTH<1) $fatal(1,"FAIL: history scheduler parameters");
    // synthesis translate_on
endmodule
