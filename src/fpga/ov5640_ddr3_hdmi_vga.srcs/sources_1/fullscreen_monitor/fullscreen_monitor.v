`timescale 1ns/1ps
////////////////////////////////////////////////////////////////////////////////////
// fullscreen_monitor - ExamGuard full-frame activity monitor.
//
// Replaces the fixed three-ROI motion detector. It keeps a low-resolution
// previous-frame reference over the WHOLE frame (same grid trick as
// motion_detect: one byte per SAMPLE_SHIFT x SAMPLE_SHIFT block) and reports:
//   - activity_global : smoothed 0..255 whole-frame activity score
//   - active_cells    : raw number of changed grid cells in the last frame
//
// No ROI coordinates are used. The reference RAM is deliberately reset-free
// (distributed RAM cannot take an asynchronous reset); every location is
// rewritten once per frame, gated by reference_ready.
////////////////////////////////////////////////////////////////////////////////////
module fullscreen_monitor #(
    parameter SAMPLE_SHIFT = 4,
    parameter GRID_WIDTH   = 80,
    parameter GRID_HEIGHT  = 45,
    parameter SCORE_SHIFT  = 4,
    parameter [7:0] NOISE_FLOOR = 8'd8
) (
    input         clk,
    input         rst,
    input  [23:0] pixel_in,
    input  [11:0] x,
    input  [11:0] y,
    input         de,
    input         sof,
    output reg [7:0]  activity_global,
    output reg [15:0] active_cells,
    output reg [7:0]  luma_avg       // per-frame average luma (scaled), for camera-block
);

    localparam GRID_SIZE = GRID_WIDTH * GRID_HEIGHT;

    (* ram_style = "distributed" *) reg [7:0] previous_frame [0:GRID_SIZE-1];
    reg         frame_started;
    reg         reference_ready;
    reg  [15:0] frame_changed_count;
    reg  [31:0] luma_sum;         // accumulated gray over the frame

    wire sample_en = de &&
                     (x[SAMPLE_SHIFT-1:0] == 0) &&
                     (y[SAMPLE_SHIFT-1:0] == 0);
    wire [7:0]  gray_now = (pixel_in[23:16] >> 2) +
                           (pixel_in[15:8]  >> 1) +
                           (pixel_in[7:0]   >> 2);
    wire [11:0] sample_x = x >> SAMPLE_SHIFT;
    wire [11:0] sample_y = y >> SAMPLE_SHIFT;
    wire [15:0] sample_addr = (sample_y * GRID_WIDTH) + sample_x;
    wire        sample_valid = sample_en &&
                               (sample_x < GRID_WIDTH) &&
                               (sample_y < GRID_HEIGHT);
    wire [15:0] safe_sample_addr = sample_valid ? sample_addr : 16'd0;

    // One-cycle pipeline so the compare no longer shares a combinational path
    // with the coordinate math (mirrors the timing fix proven in motion_detect).
    reg        sample_valid_d;
    reg [15:0] sample_addr_d;
    reg [7:0]  gray_now_d;

    wire [7:0] previous_gray = previous_frame[sample_addr_d];
    wire [8:0] gray_delta = (gray_now_d >= previous_gray) ?
                            ({1'b0, gray_now_d} - {1'b0, previous_gray}) :
                            ({1'b0, previous_gray} - {1'b0, gray_now_d});
    wire changed_cell = reference_ready && sample_valid_d &&
                        (gray_delta > NOISE_FLOOR);

    function [7:0] count_to_score;
        input [15:0] count;
        reg [31:0] scaled;
        begin
            scaled = count >> SCORE_SHIFT;
            if (scaled > 32'd255)
                count_to_score = 8'hff;
            else
                count_to_score = scaled[7:0];
        end
    endfunction

    function [7:0] smooth_score;
        input [7:0] current_score;
        input [7:0] target_score;
        reg [8:0] delta;
        reg [9:0] next_score;
        begin
            if (target_score > current_score) begin
                delta = target_score - current_score;
                next_score = current_score + ((delta + 9'd3) >> 2);
            end else begin
                delta = current_score - target_score;
                next_score = current_score - ((delta + 9'd3) >> 2);
            end
            if (next_score > 10'd255)
                smooth_score = 8'hff;
            else
                smooth_score = next_score[7:0];
        end
    endfunction

    always @(posedge clk) begin
        if (sample_valid_d)
            previous_frame[sample_addr_d] <= gray_now_d;
    end

    always @(posedge clk) begin
        if (rst) begin
            frame_started       <= 1'b0;
            reference_ready     <= 1'b0;
            frame_changed_count <= 16'd0;
            activity_global     <= 8'd0;
            active_cells        <= 16'd0;
            luma_avg            <= 8'd0;
            luma_sum            <= 32'd0;
            sample_valid_d      <= 1'b0;
            sample_addr_d       <= 16'd0;
            gray_now_d          <= 8'd0;
        end else begin
            sample_valid_d <= sample_valid;
            sample_addr_d  <= safe_sample_addr;
            gray_now_d     <= gray_now;

            if (sample_valid_d && !sof)
                luma_sum <= luma_sum + {24'd0, gray_now_d};

            if (sof) begin
                if (!frame_started) begin
                    frame_started <= 1'b1;
                end else if (!reference_ready) begin
                    reference_ready <= 1'b1;
                end else begin
                    activity_global <= smooth_score(activity_global,
                                                    count_to_score(frame_changed_count));
                    active_cells    <= frame_changed_count;
                end
                frame_changed_count <= 16'd0;
                luma_avg <= luma_sum[31:12];   // ~ average of the grid samples
                luma_sum <= 32'd0;
            end else if (changed_cell) begin
                if (frame_changed_count != 16'hffff)
                    frame_changed_count <= frame_changed_count + 1'b1;
            end
        end
    end

endmodule
