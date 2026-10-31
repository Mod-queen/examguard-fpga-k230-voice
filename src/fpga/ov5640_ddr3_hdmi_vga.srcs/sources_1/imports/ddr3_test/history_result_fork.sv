`timescale 1ns/1ps
// Hold one merged history result until BOTH consumers (EGv2 result packetizer
// and HR record) have taken it. Consumers may accept in either order.
module history_result_fork #(
    parameter integer WINDOWS=4,
    parameter integer WW=WINDOWS<2 ? 1 : $clog2(WINDOWS)
)(
    input wire clk,rst,
    input wire in_valid,output wire in_ready,
    input wire [WW-1:0] in_window,input wire [31:0] in_token,input wire [2:0] in_code,
    input wire in_ok,in_trunc,in_cap,in_gap_unknown,in_gap_bad_range,in_coverage,
    input wire [31:0] in_frames,in_gap_count,
    input wire [63:0] in_lower,in_upper,
    input wire [95:0] in_first_meta,in_last_meta,
    input wire [7:0] in_first_reason,in_last_reason,
    input wire [255:0] in_event,
    output wire a_valid,input wire a_ready,
    output wire [WW-1:0] a_window,output wire [31:0] a_token,output wire [2:0] a_code,
    output wire a_ok,a_trunc,a_cap,a_gap_unknown,a_gap_bad_range,a_coverage,
    output wire [31:0] a_frames,a_gap_count,
    output wire [63:0] a_lower,a_upper,
    output wire [95:0] a_first_meta,a_last_meta,
    output wire [7:0] a_first_reason,a_last_reason,
    output wire [255:0] a_event,
    output wire b_valid,input wire b_ready,
    output wire [WW-1:0] b_window,output wire [31:0] b_token,output wire [2:0] b_code,
    output wire b_ok,b_trunc,b_cap,b_gap_unknown,b_gap_bad_range,b_coverage,
    output wire [31:0] b_frames,b_gap_count,
    output wire [63:0] b_lower,b_upper,
    output wire [95:0] b_first_meta,b_last_meta,
    output wire [7:0] b_first_reason,b_last_reason,
    output wire [255:0] b_event
);
    reg busy,a_done,b_done;
    reg [WW-1:0] window;
    reg [31:0] token,frames,gap_count;
    reg [2:0] code;
    reg ok,trunc,cap,gap_unknown,gap_bad_range,coverage;
    reg [63:0] lower,upper;
    reg [95:0] first_meta,last_meta;
    reg [7:0] first_reason,last_reason;
    reg [255:0] evt;
    assign in_ready=!rst && !busy;
    assign a_valid=!rst && busy && !a_done;
    assign b_valid=!rst && busy && !b_done;
    assign a_window=window;assign a_token=token;assign a_code=code;assign a_ok=ok;assign a_trunc=trunc;assign a_cap=cap;
    assign a_gap_unknown=gap_unknown;assign a_gap_bad_range=gap_bad_range;assign a_coverage=coverage;
    assign a_frames=frames;assign a_gap_count=gap_count;assign a_lower=lower;assign a_upper=upper;
    assign a_first_meta=first_meta;assign a_last_meta=last_meta;assign a_first_reason=first_reason;
    assign a_last_reason=last_reason;assign a_event=evt;
    assign b_window=window;assign b_token=token;assign b_code=code;assign b_ok=ok;assign b_trunc=trunc;assign b_cap=cap;
    assign b_gap_unknown=gap_unknown;assign b_gap_bad_range=gap_bad_range;assign b_coverage=coverage;
    assign b_frames=frames;assign b_gap_count=gap_count;assign b_lower=lower;assign b_upper=upper;
    assign b_first_meta=first_meta;assign b_last_meta=last_meta;assign b_first_reason=first_reason;
    assign b_last_reason=last_reason;assign b_event=evt;
    always @(posedge clk) begin
        if(rst) begin
            busy<=0;a_done<=0;b_done<=0;window<=0;token<=0;code<=0;ok<=0;trunc<=0;cap<=0;
            gap_unknown<=0;gap_bad_range<=0;coverage<=0;frames<=0;gap_count<=0;lower<=0;upper<=0;
            first_meta<=0;last_meta<=0;first_reason<=0;last_reason<=0;evt<=0;
        end else if(!busy) begin
            if(in_valid && in_ready) begin
                busy<=1;a_done<=0;b_done<=0;
                window<=in_window;token<=in_token;code<=in_code;ok<=in_ok;trunc<=in_trunc;cap<=in_cap;
                gap_unknown<=in_gap_unknown;gap_bad_range<=in_gap_bad_range;coverage<=in_coverage;
                frames<=in_frames;gap_count<=in_gap_count;lower<=in_lower;upper<=in_upper;
                first_meta<=in_first_meta;last_meta<=in_last_meta;first_reason<=in_first_reason;
                last_reason<=in_last_reason;evt<=in_event;
            end
        end else begin
            if(a_valid && a_ready) a_done<=1;
            if(b_valid && b_ready) b_done<=1;
            if((a_done || (a_valid && a_ready)) && (b_done || (b_valid && b_ready))) busy<=0;
        end
    end
    // synthesis translate_off
    initial if(WINDOWS<1 || WW>32) $fatal(1,"FAIL: history result fork parameters");
    // synthesis translate_on
endmodule



