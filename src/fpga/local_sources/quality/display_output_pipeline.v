`timescale 1ns/1ps
// One pixel stage at the HDMI boundary. RGB and all controls stay aligned.
// No camera, DDR, overlay-content or display-counter behavior is changed.
module display_output_pipeline(
    input wire clk,rst,
    input wire [23:0] in_rgb,
    input wire in_hs,in_vs,in_de,
    output reg [23:0] out_rgb,
    output reg out_hs,out_vs,out_de
);
    always @(posedge clk) begin
        if(rst) begin
            out_rgb<=0;out_hs<=0;out_vs<=0;out_de<=0;
        end else begin
            out_rgb<=in_rgb;out_hs<=in_hs;out_vs<=in_vs;out_de<=in_de;
        end
    end
endmodule
