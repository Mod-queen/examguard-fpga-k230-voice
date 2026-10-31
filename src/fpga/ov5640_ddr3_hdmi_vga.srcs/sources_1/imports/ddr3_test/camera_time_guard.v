`timescale 1ns/1ps
// Qualifies a non-stallable frame using a coherent cap-domain time snapshot.
// A stale/unknown snapshot DISABLES THE WHOLE FRAME at SOF; existing frame_meta
// 96-bit format remains {frame_id,time_ms}, with no invented timestamp sentinel.
// Consumers latch frame_enable/frame_meta at SOF (e.g. camera_sample_guard).
// Freshness here is age since DELIVERY, not total source->pixel timestamp error.
// Counts are cap-domain saturating telemetry, not UI/host CDC outputs.
module camera_time_guard #(
    parameter [31:0] MAX_AGE_CYCLES=32'd74250 // nominal1ms at74.25MHz
)(
    input wire clk,rst,sof,enable,
    input wire [31:0] frame_id,
    input wire [63:0] time_ms,
    input wire time_valid,
    input wire [31:0] age_cycles,
    output wire frame_enable,
    output wire [95:0] frame_meta,
    output reg [31:0] rejected_unknown,rejected_stale
);
    assign frame_enable=enable && time_valid && age_cycles<=MAX_AGE_CYCLES && !rst;
    assign frame_meta={frame_id,time_ms};
    always @(posedge clk) begin
        if(rst) begin rejected_unknown<=0;rejected_stale<=0;end
        else if(sof && enable) begin
            if(!time_valid && rejected_unknown!=32'hffffffff) rejected_unknown<=rejected_unknown+1'b1;
            else if(time_valid && age_cycles>MAX_AGE_CYCLES && rejected_stale!=32'hffffffff) rejected_stale<=rejected_stale+1'b1;
        end
    end
endmodule
