`timescale 1ns/1ps
// Ignore startup SOFs until a fresh coherent source time exists. After arming,
// never mask a bad/stale snapshot: the sampler must report/cancel that epoch.
module history_startup_gate #(parameter [31:0] MAX_AGE_CYCLES=74250)(
    input wire clk,rst,sof,time_valid,
    input wire [31:0] age_cycles,
    output wire sample_open,
    output reg armed
);
    wire fresh=time_valid && age_cycles<=MAX_AGE_CYCLES;
    assign sample_open=!rst && (armed || (sof && fresh));
    always @(posedge clk) begin
        if(rst) armed<=0;
        else if(sof && fresh) armed<=1;
    end
endmodule
