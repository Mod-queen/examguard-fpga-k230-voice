`timescale 1ns/1ps

// Luma-preserving saturation boost in the display pixel path.
//
// The pixel is converted to Y and the chroma difference (R-Y, G-Y, B-Y) is
// scaled by SAT/256 before being added back. Because Y is preserved, the grey
// level used by the frame-difference motion detector is unchanged, so motion
// detection is not affected by the colour enhancement.
//
// Three pipeline stages; (x, y, de, sof) are delayed by the same amount so the
// overlay, motion detector and evidence capture stay pixel-aligned.
module color_enhance #(
    parameter integer SAT = 320  // 256 = 1.0x, 320 = 1.25x
) (
    input             clk,
    input             rst,
    input      [7:0]  pixel_r,
    input      [7:0]  pixel_g,
    input      [7:0]  pixel_b,
    input      [11:0] x,
    input      [11:0] y,
    input             de,
    input             sof,
    output reg [7:0]  enh_r,
    output reg [7:0]  enh_g,
    output reg [7:0]  enh_b,
    output reg [11:0] enh_x,
    output reg [11:0] enh_y,
    output reg        enh_de,
    output reg        enh_sof
);

    localparam integer LATENCY = 3;

    // Stage 1: luma and pixel delay.
    wire [15:0] y_sum = 16'd77 * pixel_r + 16'd150 * pixel_g + 16'd29 * pixel_b;
    wire [7:0]  luma  = y_sum[15:8];

    reg [7:0] r1, g1, b1, y1;
    always @(posedge clk) begin
        r1 <= pixel_r;
        g1 <= pixel_g;
        b1 <= pixel_b;
        y1 <= luma;
    end

    // Stage 2: chroma differences.
    reg signed [8:0] dr2, dg2, db2;
    reg [7:0] y2;
    always @(posedge clk) begin
        dr2 <= $signed({1'b0, r1}) - $signed({1'b0, y1});
        dg2 <= $signed({1'b0, g1}) - $signed({1'b0, y1});
        db2 <= $signed({1'b0, b1}) - $signed({1'b0, y1});
        y2  <= y1;
    end

    // Stage 3: scale chroma, add luma, clamp.
    function [7:0] sat8;
        input signed [17:0] v;
        begin
            if (v < 0)
                sat8 = 8'd0;
            else if (v > 255)
                sat8 = 8'd255;
            else
                sat8 = v[7:0];
        end
    endfunction

    always @(posedge clk) begin
        enh_r <= sat8($signed({1'b0, y2}) + ((dr2 * SAT) >>> 8));
        enh_g <= sat8($signed({1'b0, y2}) + ((dg2 * SAT) >>> 8));
        enh_b <= sat8($signed({1'b0, y2}) + ((db2 * SAT) >>> 8));
    end

    // Coordinate pipeline, aligned with the pixel pipeline.
    reg [11:0] x_d [0:LATENCY-1];
    reg [11:0] y_d [0:LATENCY-1];
    reg        de_d [0:LATENCY-1];
    reg        sof_d[0:LATENCY-1];
    integer i;
    always @(posedge clk) begin
        x_d[0]   <= x;
        y_d[0]   <= y;
        de_d[0]  <= de;
        sof_d[0] <= sof;
        for (i = 1; i < LATENCY; i = i + 1) begin
            x_d[i]   <= x_d[i-1];
            y_d[i]   <= y_d[i-1];
            de_d[i]  <= de_d[i-1];
            sof_d[i] <= sof_d[i-1];
        end
        enh_x   <= x_d[LATENCY-1];
        enh_y   <= y_d[LATENCY-1];
        enh_de  <= de_d[LATENCY-1];
        enh_sof <= sof_d[LATENCY-1];
    end

endmodule
