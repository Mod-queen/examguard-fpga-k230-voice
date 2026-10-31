`timescale 1ns/1ps

// Read-only tap of the existing PRE-OVERLAY display RGB stream (not raw PCLK).
// Samples a coordinate grid and selects every FRAME_INTERVAL-th source frame.
// Default 1280x720 / 4 = 320x180; interval6 is nominal 10fps ONLY at 60Hz input.
// Actual retained rate may be lower; source frame/time metadata stays explicit.
// No ready on input: full banks drop WHOLE frames at START. Incomplete/missing
// grid samples must never be packed into an apparently complete DDR frame.
//
// frame_meta={frame_id32,time_ms64} MUST be coherent in this clock domain at SOF.
// This module does NOT synchronize metadata, timestamps, or enable from control.
// SOF may coincide with DE/x0/y0: start and first sample are pipelined together.
module camera_sample_guard #(
    parameter integer SRC_WIDTH=1280,SRC_HEIGHT=720,SAMPLE_STRIDE=4,
    parameter integer FRAME_INTERVAL=6,
    parameter integer FRAME_WIDTH=SRC_WIDTH/SAMPLE_STRIDE,
    parameter integer FRAME_HEIGHT=SRC_HEIGHT/SAMPLE_STRIDE,
    parameter integer INDEX_W=FRAME_WIDTH*FRAME_HEIGHT<2 ? 1 : $clog2(FRAME_WIDTH*FRAME_HEIGHT)
)(
    input wire clk,rst,enable,
    input wire [7:0] pixel_r,pixel_g,pixel_b,
    input wire [11:0] x,y,
    input wire de,sof,
    input wire [95:0] frame_meta,
    output wire out_valid,out_sof,out_last,
    output wire [15:0] out_data,
    output wire [95:0] out_meta,
    input wire out_ready,
    output wire [1:0] banks_occupied,
    output wire [31:0] frames_seen,frames_buffered,frames_sent,
    output wire [31:0] dropped_busy,dropped_invalid,dropped_disabled
);
    localparam integer INTERVAL_W=FRAME_INTERVAL<2 ? 1 : $clog2(FRAME_INTERVAL);
    reg [INTERVAL_W-1:0] interval_count;
    reg started,selected;
    wire select_now=enable && interval_count==0;
    wire grid=de && x<SRC_WIDTH && y<SRC_HEIGHT &&
        (x%SAMPLE_STRIDE)==0 && (y%SAMPLE_STRIDE)==0;
    reg sample_start,sample_end,sample_enable,sample_valid,sample_last;
    reg [INDEX_W-1:0] sample_index;
    reg [15:0] sample_data;
    reg [95:0] sample_meta;
    always @(posedge clk) begin
        if(rst) begin
            interval_count<=0;started<=0;selected<=0;
            sample_start<=0;sample_end<=0;sample_enable<=0;
            sample_valid<=0;sample_last<=0;sample_index<=0;sample_data<=0;sample_meta<=0;
        end else begin
            sample_start<=sof;
            sample_end<=de && x==SRC_WIDTH-1 && y==SRC_HEIGHT-1;
            sample_valid<=grid && (sof ? select_now : started && selected);
            sample_last<=grid && x==SRC_WIDTH-SAMPLE_STRIDE && y==SRC_HEIGHT-SAMPLE_STRIDE;
            // Coordinate-derived index exposes skipped/duplicated/out-of-order
            // samples to the guard. A running count here would hide bad frames.
            sample_index<=(y/SAMPLE_STRIDE)*FRAME_WIDTH+x/SAMPLE_STRIDE;
            sample_data<={pixel_r[7:3],pixel_g[7:2],pixel_b[7:3]};
            if(sof) begin
                started<=1;selected<=select_now;sample_enable<=select_now;
                sample_meta<=frame_meta;
                interval_count<=interval_count==FRAME_INTERVAL-1 ? 0 : interval_count+1'b1;
            end
        end
    end
    camera_frame_guard #(.FRAME_PIXELS(FRAME_WIDTH*FRAME_HEIGHT),.INDEX_W(INDEX_W)) guard(
        .clk(clk),.rst(rst),.enable(sample_enable),.frame_start(sample_start),.frame_end(sample_end),
        .in_valid(sample_valid),.in_index(sample_index),.in_data(sample_data),.in_last(sample_last),.in_meta(sample_meta),
        .out_valid(out_valid),.out_sof(out_sof),.out_last(out_last),.out_data(out_data),.out_meta(out_meta),.out_ready(out_ready),
        .banks_occupied(banks_occupied),.frames_seen(frames_seen),.frames_buffered(frames_buffered),.frames_sent(frames_sent),
        .dropped_busy(dropped_busy),.dropped_invalid(dropped_invalid),.dropped_disabled(dropped_disabled));
    // synthesis translate_off
    initial if(SRC_WIDTH<1 || SRC_HEIGHT<1 || SRC_WIDTH>4096 || SRC_HEIGHT>4096 || SAMPLE_STRIDE<1 ||
        (SAMPLE_STRIDE & (SAMPLE_STRIDE-1))!=0 || SRC_WIDTH%SAMPLE_STRIDE || SRC_HEIGHT%SAMPLE_STRIDE ||
        FRAME_INTERVAL<1 || FRAME_WIDTH!=SRC_WIDTH/SAMPLE_STRIDE || FRAME_HEIGHT!=SRC_HEIGHT/SAMPLE_STRIDE)
        $fatal(1,"FAIL: unsupported camera_sample_guard geometry/cadence");
    // synthesis translate_on
endmodule
