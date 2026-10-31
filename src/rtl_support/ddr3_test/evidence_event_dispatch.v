`timescale 1ns/1ps

// UI-clock pulse queue + one-window-at-a-time dispatcher. Payload is the
// existing 256-bit event transaction (device/boot/session/uid/source_ms/lane).
// Unlike a boolean pending, every ACCEPTED request has its own immutable
// payload and eventually one result, unless system reset cancels the epoch.
// This is explicitly deferred SERVICE anchoring, not retroactive capture at
// event_time. deferred=1 flags requests accepted while an earlier window/result
// was outstanding. Readout/result backpressure stops further dispatch.
module evidence_event_dispatch #(
    parameter integer DEPTH=4,
    parameter integer PTR_W=DEPTH<2 ? 1 : $clog2(DEPTH),
    parameter integer COUNT_W=$clog2(DEPTH+1)
)(
    input wire clk, rst,
    input wire request,
    input wire [255:0] request_data,
    output wire accepted, rejected,
    output wire [COUNT_W-1:0] occupancy,
    output reg [COUNT_W-1:0] high_water,
    output reg [31:0] accepted_count, rejected_count, completed_count,
    input wire engine_ready,
    output wire engine_event,
    input wire window_started,
    input wire [31:0] window_frames,
    input wire window_done, window_ok,
    output reg active,
    output reg [255:0] active_event,
    output reg active_deferred,
    output reg result_valid,
    input wire result_ready,
    output reg [255:0] result_event,
    output reg result_deferred, result_ok,
    output reg [31:0] result_frames
);
    (* ram_style = "distributed" *) reg [255:0] payload [0:DEPTH-1];
    reg deferred [0:DEPTH-1];
    reg [PTR_W-1:0] wr_ptr, rd_ptr;
    reg [COUNT_W-1:0] count;
    reg [31:0] active_frames;
    wire dispatch = !rst && count!=0 && !active && !result_valid && engine_ready;
    assign occupancy=count;
    assign engine_event=dispatch;
    assign accepted = !rst && request && (count<DEPTH || dispatch);
    assign rejected = !rst && request && !accepted;
    wire [COUNT_W-1:0] count_next = count + accepted - dispatch;
    function [PTR_W-1:0] advance;
        input [PTR_W-1:0] p;
        begin advance = p==DEPTH-1 ? 0 : p+1'b1; end
    endfunction
    function [31:0] inc_sat;
        input [31:0] n;
        begin inc_sat=n==32'hffffffff ? n : n+1'b1; end
    endfunction
    always @(posedge clk) begin
        if(rst) begin
            wr_ptr<=0; rd_ptr<=0; count<=0; high_water<=0;
            accepted_count<=0; rejected_count<=0; completed_count<=0;
            active<=0; active_event<=0; active_deferred<=0; active_frames<=0;
            result_valid<=0; result_event<=0; result_deferred<=0; result_ok<=0; result_frames<=0;
        end else begin
            count<=count_next;
            if(count_next>high_water) high_water<=count_next;
            if(accepted) begin
                payload[wr_ptr]<=request_data;
                deferred[wr_ptr]<=active || result_valid || count!=0 || !engine_ready;
                wr_ptr<=advance(wr_ptr); accepted_count<=inc_sat(accepted_count);
            end
            if(rejected) rejected_count<=inc_sat(rejected_count);
            if(dispatch) begin
                active<=1; active_event<=payload[rd_ptr]; active_deferred<=deferred[rd_ptr];
                active_frames<=0; rd_ptr<=advance(rd_ptr);
            end
            if(active && window_started) active_frames<=window_frames;
            if(result_valid && result_ready) result_valid<=0;
            if(active && window_done) begin
                active<=0; result_valid<=1; result_event<=active_event;
                result_deferred<=active_deferred; result_ok<=window_ok;
                result_frames<=window_started ? window_frames : active_frames;
                completed_count<=inc_sat(completed_count);
            end
        end
    end
    // synthesis translate_off
    initial if(DEPTH<1) $fatal(1,"FAIL: evidence event queue depth");
    // synthesis translate_on
endmodule
