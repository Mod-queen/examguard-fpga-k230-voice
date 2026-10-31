`timescale 1ns/1ps
// Read-only PRE-OVERLAY display RGB tap, not a raw DVP camera capture.
// Input time snapshot must already be coherent in clk domain. Cadence selects
// source frames independently of enable; disabled selected frames become DROP.
// Skipped cadence frames do NOT create fake gaps or advance the source fence.
// Unknown/stale time on a selected SOF halts the source epoch, since an accurate
// point-gap/fence timestamp cannot be invented. Caller owns common cancellation.
module history_sample_source #(
    parameter integer SRC_WIDTH=1280,SRC_HEIGHT=720,SAMPLE_STRIDE=4,FRAME_INTERVAL=6,
    parameter integer DEPTH=16,
    parameter [31:0] MAX_AGE_CYCLES=74250,
    parameter integer CW=$clog2(DEPTH+1)
)(
    input wire clk,rst,enable,
    input wire [7:0] pixel_r,pixel_g,pixel_b,
    input wire [11:0] x,y,
    input wire de,sof,
    input wire [31:0] frame_id,
    input wire [63:0] time_ms,
    input wire time_valid,input wire [31:0] age_cycles,
    output wire command_valid,input wire command_ready,
    output wire [1:0] command_kind,output wire [95:0] command_meta,output wire [7:0] command_reason,
    output wire pixel_valid,input wire pixel_ready,
    output wire pixel_last,output wire [15:0] pixel_data,
    output wire halted,output wire [2:0] halt_reason,
    output wire [CW-1:0] occupancy,output wire [1:0] banks_occupied,
    output wire [31:0] frames_seen,frames_published,frames_dropped,decisions_sent,
    output reg [31:0] source_sofs,cadence_skipped,time_unknown,time_stale
);
    localparam FW=SRC_WIDTH/SAMPLE_STRIDE,FH=SRC_HEIGHT/SAMPLE_STRIDE,FP=FW*FH;
    localparam IW=FP<2?1:$clog2(FP),TW=FRAME_INTERVAL<2?1:$clog2(FRAME_INTERVAL);
    reg [TW-1:0] cadence;
    reg started,selected;
    wire choose=cadence==0;
    wire grid=de && x<SRC_WIDTH && y<SRC_HEIGHT && x%SAMPLE_STRIDE==0 && y%SAMPLE_STRIDE==0;
    reg sample_start,sample_end,sample_enable,sample_time_valid,sample_valid,sample_last;
    reg [95:0] sample_meta;
    reg [IW-1:0] sample_index;
    reg [15:0] sample_data;
    function [31:0] inc_sat(input [31:0] n);
        inc_sat=n==32'hffffffff ? n : n+1'b1;
    endfunction
    always @(posedge clk) begin
        if(rst) begin
            cadence<=0;started<=0;selected<=0;
            sample_start<=0;sample_end<=0;sample_enable<=0;sample_time_valid<=0;
            sample_valid<=0;sample_last<=0;sample_meta<=0;sample_index<=0;sample_data<=0;
            source_sofs<=0;cadence_skipped<=0;time_unknown<=0;time_stale<=0;
        end else if(!halted) begin
            sample_start<=sof && choose;
            // A skipped next SOF still terminates an unfinished chosen frame.
            // A chosen next SOF is handled as interruption by the producer.
            sample_end<=(sof && !choose) || (de && x==SRC_WIDTH-1 && y==SRC_HEIGHT-1);
            sample_valid<=grid && (sof ? choose : started && selected);
            sample_last<=grid && x==SRC_WIDTH-SAMPLE_STRIDE && y==SRC_HEIGHT-SAMPLE_STRIDE;
            sample_index<=(y/SAMPLE_STRIDE)*FW+x/SAMPLE_STRIDE;
            sample_data<={pixel_r[7:3],pixel_g[7:2],pixel_b[7:3]};
            if(sof) begin
                started<=1;selected<=choose;
                cadence<=cadence==FRAME_INTERVAL-1 ? 0 : cadence+1'b1;
                source_sofs<=inc_sat(source_sofs);
                if(!choose) cadence_skipped<=inc_sat(cadence_skipped);
                else begin
                    sample_enable<=enable;
                    sample_time_valid<=time_valid && age_cycles<=MAX_AGE_CYCLES;
                    sample_meta<={frame_id,time_ms};
                    if(!time_valid) time_unknown<=inc_sat(time_unknown);
                    else if(age_cycles>MAX_AGE_CYCLES) time_stale<=inc_sat(time_stale);
                end
            end
        end
    end
    history_capture_source #(.FRAME_PIXELS(FP),.DEPTH(DEPTH)) source(
        .clk(clk),.rst(rst),.frame_start(sample_start),.frame_end(sample_end),
        .enable(sample_enable),.time_valid(sample_time_valid),.in_meta(sample_meta),
        .in_valid(sample_valid),.in_last(sample_last),.in_index(sample_index),.in_data(sample_data),
        .command_valid(command_valid),.command_ready(command_ready),.command_kind(command_kind),.command_meta(command_meta),.command_reason(command_reason),
        .pixel_valid(pixel_valid),.pixel_ready(pixel_ready),.pixel_last(pixel_last),.pixel_data(pixel_data),
        .halted(halted),.halt_reason(halt_reason),.occupancy(occupancy),.banks_occupied(banks_occupied),
        .frames_seen(frames_seen),.frames_published(frames_published),.frames_dropped(frames_dropped),.decisions_sent(decisions_sent));
    // synthesis translate_off
    initial if(SRC_WIDTH<1 || SRC_HEIGHT<1 || SRC_WIDTH>4096 || SRC_HEIGHT>4096 || SAMPLE_STRIDE<1 ||
        (SAMPLE_STRIDE & (SAMPLE_STRIDE-1))!=0 || SRC_WIDTH%SAMPLE_STRIDE || SRC_HEIGHT%SAMPLE_STRIDE || FRAME_INTERVAL<1)
        $fatal(1,"FAIL: history sampler geometry/cadence");
    // synthesis translate_on
endmodule
