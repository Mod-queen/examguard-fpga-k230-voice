`timescale 1ns/1ps
// Single UI-domain descriptor/reference directory. No DMA or pixel memory.
// See docs/history_reference_contract.md; reset must cancel all users and AXI.
module history_reference_directory #(
    parameter integer SLOTS=64, WINDOWS=4,
    parameter integer ENABLE_WINDOW_TOKENS=0, // legacy harnesses; new coordinator requires 1
    parameter [63:0] PRE_MS=2000, POST_MS=2000,
    parameter integer SW=SLOTS<2?1:$clog2(SLOTS),
    parameter integer WW=WINDOWS<2?1:$clog2(WINDOWS)
)(
    input wire clk,rst,
    input wire reserve_valid, output wire reserve_ready,
    output reg grant_valid, input wire grant_ready,
    output reg grant_ok, output reg [SW-1:0] grant_slot,
    output reg [31:0] grant_token,
    input wire finish_valid, output wire finish_ready,
    input wire [SW-1:0] finish_slot,
    input wire [31:0] finish_token,
    input wire finish_ok, input wire [95:0] finish_meta,
    input wire request_valid, output wire request_ready,
    input wire [255:0] request_event,
    output reg accepted, output reg [WW-1:0] accepted_window,
    output reg [31:0] accepted_token,
    output reg window_token_exhausted,
    input wire seal_valid, output wire seal_ready,
    input wire [63:0] seal_time,
    input wire release_valid, output wire release_ready,
    input wire [WW-1:0] release_window,
    input wire [31:0] release_token,
    output reg release_done,release_ok,
    input wire [WW-1:0] query_window,
    output wire query_active,query_closed,query_truncated,query_capture_error,
    output wire [SLOTS-1:0] query_slots,
    output wire [255:0] query_event,
    output wire [31:0] query_token,
    input wire [SW-1:0] query_slot,
    output wire slot_valid, output wire [95:0] slot_meta,
    output wire [SLOTS-1:0] protected_slots,
    output wire writer_pending_o,
    output wire [WINDOWS-1:0] active_mask,closed_mask,
    output reg protocol_fault,token_exhausted,
    output reg [31:0] reserve_rejected,write_failed
);
    localparam IDLE=0,ALLOC=1,SCAN=2;
    reg [1:0] state;
    reg [SW-1:0] cursor,scan_slot;
    reg [SW:0] scanned;
    reg [WW-1:0] scan_window;
    reg [SLOTS-1:0] valid_slots;
    reg [95:0] metadata[0:SLOTS-1];
    reg [SLOTS-1:0] refs[0:WINDOWS-1];
    reg [WINDOWS-1:0] active,closed,truncated,capture_error;
    reg [63:0] lower[0:WINDOWS-1],upper[0:WINDOWS-1];
    reg [255:0] events[0:WINDOWS-1];
    reg [31:0] window_tokens[0:WINDOWS-1];
    reg [31:0] next_window_token;
    reg writer_pending,writer_issued;
    reg [SW-1:0] reserved_slot;
    reg [31:0] reserved_token,next_token;
    reg have_history,have_evicted,have_seal;
    reg [63:0] first_time,last_time,evicted_through,sealed_through;
    reg [SLOTS-1:0] all_refs;
    reg free_window;
    reg [WW-1:0] free_index;
    integer i,j;
    always @* begin
        all_refs=0;free_window=0;free_index=0;
        for(j=0;j<WINDOWS;j=j+1) begin
            if(active[j]) all_refs=all_refs|refs[j];
            if(!active[j] && !free_window) begin free_window=1;free_index=j;end
        end
    end
    function [SW-1:0] advance;
        input [SW-1:0] s;
        begin advance=s==SLOTS-1?0:s+1'b1;end
    endfunction
    function [31:0] inc_sat;
        input [31:0] n;
        begin inc_sat=n==32'hffffffff ? n : n+1'b1;end
    endfunction
    wire idle=!rst && state==IDLE;
    // Explicit single-command priority. Callers hold valid/data until ready.
    assign finish_ready=idle;
    assign release_ready=idle && !finish_valid;
    assign seal_ready=idle && !finish_valid && !release_valid;
    assign request_ready=idle && !finish_valid && !release_valid && !seal_valid && free_window &&
                         (!ENABLE_WINDOW_TOKENS || !window_token_exhausted);
    assign reserve_ready=idle && !finish_valid && !release_valid && !seal_valid && !request_valid && !writer_pending && !grant_valid;
    wire [63:0] event_time=request_event[95:32];
    wire [63:0] request_lower=event_time<PRE_MS?64'd0:event_time-PRE_MS;
    wire [63:0] request_upper=(64'hffffffffffffffff-event_time<POST_MS)?64'hffffffffffffffff:event_time+POST_MS;
    wire good_time=(!have_history || finish_meta[63:0]>last_time) && (!have_seal || finish_meta[63:0]>sealed_through);
    assign protected_slots=all_refs;
    assign writer_pending_o=writer_pending;
    assign active_mask=active;
    assign closed_mask=closed;
    assign query_active=query_window<WINDOWS?active[query_window]:1'b0;
    assign query_closed=query_window<WINDOWS?closed[query_window]:1'b0;
    assign query_truncated=query_window<WINDOWS?truncated[query_window]:1'b0;
    assign query_capture_error=query_window<WINDOWS?capture_error[query_window]:1'b0;
    assign query_slots=query_window<WINDOWS?refs[query_window]:{SLOTS{1'b0}};
    assign query_event=query_window<WINDOWS?events[query_window]:256'd0;
    assign query_token=query_active ? window_tokens[query_window] : 32'd0;
    assign slot_valid=query_slot<SLOTS?valid_slots[query_slot]:1'b0;
    assign slot_meta=slot_valid?metadata[query_slot]:96'd0;
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;cursor<=0;scan_slot<=0;scanned<=0;scan_window<=0;
            valid_slots<=0;active<=0;closed<=0;truncated<=0;capture_error<=0;
            writer_pending<=0;writer_issued<=0;reserved_slot<=0;reserved_token<=0;next_token<=1;
            grant_valid<=0;grant_ok<=0;grant_slot<=0;grant_token<=0;accepted<=0;accepted_window<=0;
            accepted_token<=0;next_window_token<=1;window_token_exhausted<=0;release_done<=0;release_ok<=0;
            have_history<=0;have_evicted<=0;have_seal<=0;first_time<=0;last_time<=0;evicted_through<=0;sealed_through<=0;
            protocol_fault<=0;token_exhausted<=0;reserve_rejected<=0;write_failed<=0;
            for(i=0;i<WINDOWS;i=i+1) begin refs[i]<=0;lower[i]<=0;upper[i]<=0;events[i]<=0;window_tokens[i]<=0;end
        end else begin
            accepted<=0;
            release_done<=0;
            if(grant_valid && grant_ready) begin
                grant_valid<=0;
                if(grant_ok) writer_issued<=1;
            end
            case(state)
                IDLE: begin
                    if(finish_valid && finish_ready) begin
                        if(!writer_pending || !writer_issued || finish_slot!=reserved_slot || finish_token!=reserved_token)
                            protocol_fault<=1;
                        else begin
                            writer_pending<=0;writer_issued<=0;
                            if(finish_ok && good_time) begin
                                metadata[reserved_slot]<=finish_meta;valid_slots[reserved_slot]<=1;
                                have_history<=1;last_time<=finish_meta[63:0];
                                if(!have_history) first_time<=finish_meta[63:0];
                                for(i=0;i<WINDOWS;i=i+1)
                                    if(active[i] && !closed[i] && finish_meta[63:0]>=lower[i] && finish_meta[63:0]<=upper[i]) refs[i][reserved_slot]<=1;
                            end else begin
                                write_failed<=inc_sat(write_failed);
                                if(finish_ok && !good_time) protocol_fault<=1;
                                for(i=0;i<WINDOWS;i=i+1)
                                    if(active[i] && !closed[i] && finish_meta[63:0]>=lower[i] && finish_meta[63:0]<=upper[i]) capture_error[i]<=1;
                            end
                        end
                    end else if(release_valid && release_ready) begin
                        release_done<=1;release_ok<=0;
                        if(release_window>=WINDOWS || !active[release_window] ||
                           (ENABLE_WINDOW_TOKENS && release_token!=window_tokens[release_window])) protocol_fault<=1;
                        else begin
                            release_ok<=1;
                            active[release_window]<=0;closed[release_window]<=0;refs[release_window]<=0;
                            truncated[release_window]<=0;capture_error[release_window]<=0;events[release_window]<=0;
                        end
                    end else if(seal_valid && seal_ready) begin
                        // Cannot seal past an unfinished DMA, even if its time
                        // is outside windows; the caller retries after finish.
                        if(writer_pending || (have_seal && seal_time<sealed_through)) protocol_fault<=1;
                        else begin
                            have_seal<=1;sealed_through<=seal_time;
                            for(i=0;i<WINDOWS;i=i+1) if(active[i] && seal_time>=upper[i]) closed[i]<=1;
                        end
                    end else if(request_valid && request_ready) begin
                        active[free_index]<=1;closed[free_index]<=0;capture_error[free_index]<=0;refs[free_index]<=0;
                        truncated[free_index]<=!have_history || request_lower<first_time || (have_evicted && request_lower<=evicted_through);
                        events[free_index]<=request_event;lower[free_index]<=request_lower;upper[free_index]<=request_upper;
                        scan_window<=free_index;scan_slot<=0;state<=SCAN;
                        accepted<=1;accepted_window<=free_index;
                        if(ENABLE_WINDOW_TOKENS) begin
                            accepted_token<=next_window_token;window_tokens[free_index]<=next_window_token;
                            if(next_window_token==32'hffffffff) window_token_exhausted<=1;
                            else next_window_token<=next_window_token+1'b1;
                        end else begin accepted_token<=0;window_tokens[free_index]<=0;end
                    end else if(reserve_valid && reserve_ready) begin
                        if(token_exhausted) begin grant_valid<=1;grant_ok<=0;reserve_rejected<=inc_sat(reserve_rejected);end
                        else begin state<=ALLOC;scan_slot<=cursor;scanned<=0;end
                    end
                end
                ALLOC: begin
                    if(!all_refs[scan_slot]) begin
                        if(valid_slots[scan_slot]) begin
                            have_evicted<=1;
                            if(!have_evicted || metadata[scan_slot][63:0]>evicted_through) evicted_through<=metadata[scan_slot][63:0];
                        end
                        valid_slots[scan_slot]<=0;reserved_slot<=scan_slot;reserved_token<=next_token;
                        writer_pending<=1;writer_issued<=0;grant_valid<=1;grant_ok<=1;grant_slot<=scan_slot;grant_token<=next_token;
                        if(next_token==32'hffffffff) token_exhausted<=1;else next_token<=next_token+1'b1;
                        cursor<=advance(scan_slot);state<=IDLE;
                    end else if(scanned==SLOTS-1) begin
                        grant_valid<=1;grant_ok<=0;reserve_rejected<=inc_sat(reserve_rejected);state<=IDLE;
                    end else begin scanned<=scanned+1'b1;scan_slot<=advance(scan_slot);end
                end
                SCAN: begin
                    if(valid_slots[scan_slot] && metadata[scan_slot][63:0]>=lower[scan_window] && metadata[scan_slot][63:0]<=upper[scan_window])
                        refs[scan_window][scan_slot]<=1;
                    if(scan_slot==SLOTS-1) begin
                        closed[scan_window]<=have_seal && sealed_through>=upper[scan_window];state<=IDLE;
                    end else scan_slot<=scan_slot+1'b1;
                end
                default: begin state<=IDLE;protocol_fault<=1;end
            endcase
        end
    end
    // synthesis translate_off
    initial if(SLOTS<1 || WINDOWS<1) $fatal(1,"FAIL: history directory parameters");
    // synthesis translate_on
endmodule
