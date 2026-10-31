`timescale 1ns/1ps

module motion_detect #(
    parameter SAMPLE_SHIFT = 4,
    parameter GRID_WIDTH = 80,
    parameter GRID_HEIGHT = 45,
    parameter SCORE_SHIFT = 0,
    parameter FRAME_NOISE_FLOOR = 8'd3,
    parameter GLOBAL_ACTIVITY_THRESHOLD = 8'd8
) (
    input         clk,
    input         rst,
    input  [23:0] pixel_in,
    input  [11:0] x,
    input  [11:0] y,
    input         de,
    input         sof,
    // Runtime regions of interest. The top level applies a new set only at a
    // frame boundary, so detection and overlay always share one revision.
    input  [11:0] roi_pickup_x0,
    input  [11:0] roi_pickup_y0,
    input  [11:0] roi_pickup_x1,
    input  [11:0] roi_pickup_y1,
    input  [11:0] roi_operation_x0,
    input  [11:0] roi_operation_y0,
    input  [11:0] roi_operation_x1,
    input  [11:0] roi_operation_y1,
    input  [11:0] roi_forbidden_x0,
    input  [11:0] roi_forbidden_y0,
    input  [11:0] roi_forbidden_x1,
    input  [11:0] roi_forbidden_y1,
    input  [7:0]  thr_pickup,
    input  [7:0]  thr_operation,
    input  [7:0]  thr_forbidden,
    output reg [7:0] motion_pickup,
    output reg [7:0] motion_operation,
    output reg [7:0] motion_forbidden,
    output reg [7:0] motion_global
);

    // One gray sample represents a SAMPLE_SHIFT x SAMPLE_SHIFT image block.
    // At 1280x720 this is only 80x45 bytes, so the design does not need a
    // full-resolution frame buffer or a single background value per ROI.
    localparam GRID_SIZE = GRID_WIDTH * GRID_HEIGHT;
    (* ram_style = "distributed" *) reg [7:0] previous_frame [0:GRID_SIZE-1];
    reg       frame_started;
    reg       reference_ready;

    reg [11:0] frame_pickup_count;
    reg [11:0] frame_operation_count;
    reg [11:0] frame_forbidden_count;

    wire sample_en = de &&
                      (x[SAMPLE_SHIFT-1:0] == 0) &&
                      (y[SAMPLE_SHIFT-1:0] == 0);
    wire [7:0] gray_now = (pixel_in[23:16] >> 2) +
                          (pixel_in[15:8]  >> 1) +
                          (pixel_in[7:0]   >> 2);
    wire [11:0] sample_x = x >> SAMPLE_SHIFT;
    wire [11:0] sample_y = y >> SAMPLE_SHIFT;
    wire [15:0] sample_addr = (sample_y * GRID_WIDTH) + sample_x;
    wire sample_valid = sample_en &&
                        (sample_x < GRID_WIDTH) &&
                        (sample_y < GRID_HEIGHT);
    wire [15:0] safe_sample_addr = sample_valid ? sample_addr : 16'd0;

    wire [11:0] pickup_x0_sample = roi_pickup_x0 >> SAMPLE_SHIFT;
    wire [11:0] pickup_x1_sample = roi_pickup_x1 >> SAMPLE_SHIFT;
    wire [11:0] pickup_y0_sample = roi_pickup_y0 >> SAMPLE_SHIFT;
    wire [11:0] pickup_y1_sample = roi_pickup_y1 >> SAMPLE_SHIFT;
    wire [11:0] operation_x0_sample = roi_operation_x0 >> SAMPLE_SHIFT;
    wire [11:0] operation_x1_sample = roi_operation_x1 >> SAMPLE_SHIFT;
    wire [11:0] operation_y0_sample = roi_operation_y0 >> SAMPLE_SHIFT;
    wire [11:0] operation_y1_sample = roi_operation_y1 >> SAMPLE_SHIFT;
    wire [11:0] forbidden_x0_sample = roi_forbidden_x0 >> SAMPLE_SHIFT;
    wire [11:0] forbidden_x1_sample = roi_forbidden_x1 >> SAMPLE_SHIFT;
    wire [11:0] forbidden_y0_sample = roi_forbidden_y0 >> SAMPLE_SHIFT;
    wire [11:0] forbidden_y1_sample = roi_forbidden_y1 >> SAMPLE_SHIFT;

    wire in_pickup = (sample_x >= pickup_x0_sample) &&
                     (sample_x < pickup_x1_sample) &&
                     (sample_y >= pickup_y0_sample) &&
                     (sample_y < pickup_y1_sample);
    wire in_operation = (sample_x >= operation_x0_sample) &&
                         (sample_x < operation_x1_sample) &&
                         (sample_y >= operation_y0_sample) &&
                         (sample_y < operation_y1_sample);
    wire in_forbidden = (sample_x >= forbidden_x0_sample) &&
                        (sample_x < forbidden_x1_sample) &&
                        (sample_y >= forbidden_y0_sample) &&
                        (sample_y < forbidden_y1_sample);
    wire in_any_roi = in_pickup || in_operation || in_forbidden;
    wire [7:0] pixel_threshold = in_pickup ? thr_pickup :
                                  (in_operation ? thr_operation :
                                   thr_forbidden);

    // ---------------------------------------------------------------------
    // Sample pipeline.
    //
    // The coordinate comparisons, the region decode and the frame-RAM address
    // are captured one clock earlier. The frame RAM read, the difference
    // comparison and the ROI counter enables therefore no longer share a
    // single combinational path with the pixel coordinate logic, which was
    // the worst setup path in the placed design.
    //
    // The reference write is delayed by the same clock, so the delayed read
    // still observes the previous frame value (the write happens after the
    // comparison in the same cycle). Sample addresses are unique within a
    // frame, so no read/write collision can occur.
    // ---------------------------------------------------------------------
    reg        sample_valid_d;
    reg [15:0] sample_addr_d;
    reg [7:0]  gray_now_d;
    reg [7:0]  pixel_threshold_d;
    reg        in_pickup_d;
    reg        in_operation_d;
    reg        in_forbidden_d;
    reg        in_any_roi_d;

    wire [7:0] previous_gray = previous_frame[sample_addr_d];
    wire [8:0] gray_delta = (gray_now_d >= previous_gray) ?
                             ({1'b0, gray_now_d} - {1'b0, previous_gray}) :
                             ({1'b0, previous_gray} - {1'b0, gray_now_d});
    wire changed_pixel = reference_ready && sample_valid_d &&
                         in_any_roi_d &&
                         (gray_delta > pixel_threshold_d);

    wire [7:0] raw_pickup = count_to_score(frame_pickup_count);
    wire [7:0] raw_operation = count_to_score(frame_operation_count);
    wire [7:0] raw_forbidden = count_to_score(frame_forbidden_count);
    wire [7:0] raw_global_unfiltered = max3(raw_pickup, raw_operation, raw_forbidden);
    // Keep the debug/global indicator quiet for a few isolated noisy blocks.
    wire [7:0] raw_global = (raw_global_unfiltered >= GLOBAL_ACTIVITY_THRESHOLD) ?
                            raw_global_unfiltered : 8'd0;

    function [7:0] count_to_score;
        input [11:0] count;
        reg [15:0] scaled_count;
        begin
            scaled_count = count >> SCORE_SHIFT;
            if (scaled_count > 16'd255)
                count_to_score = 8'hff;
            else
                count_to_score = scaled_count[7:0];
        end
    endfunction

    function [7:0] max3;
        input [7:0] a;
        input [7:0] b;
        input [7:0] c;
        begin
            if (a >= b && a >= c)
                max3 = a;
            else if (b >= c)
                max3 = b;
            else
                max3 = c;
        end
    endfunction

    function [7:0] smooth_score;
    input [7:0] current_score;
    input [7:0] target_score;
    reg [8:0] delta;
    reg [9:0] next_score;
    reg [7:0] target_value;
    begin
        // The floor gates small targets; it must not freeze a non-zero
        // score forever, otherwise one noisy frame becomes permanent.
        if (target_score <= FRAME_NOISE_FLOOR)
                target_value = 8'd0;
            else
                target_value = target_score;

            if (target_value > current_score) begin
                delta = target_value - current_score;
                next_score = current_score + ((delta + 9'd3) >> 2);
            end else begin
                delta = current_score - target_value;
                next_score = current_score - ((delta + 9'd3) >> 2);
            end

            if (next_score > 10'd255)
                smooth_score = 8'hff;
            else
                smooth_score = next_score[7:0];
        end
    endfunction

    // The reference memory is deliberately free of any reset. Distributed RAM
    // cannot take an asynchronous reset, so the synthesizer would otherwise
    // implement the reset by gating the write enable, which dragged the DDR3
    // calibration signal into this pixel-domain write path and created tens of
    // thousands of paths that were timed against a near-zero requirement.
    // Every location is rewritten once per frame, so no reset is needed.
    always @(posedge clk) begin
        if (sample_valid_d)
            previous_frame[sample_addr_d] <= gray_now_d;
    end

    // Control and score logic uses a synchronous reset so no asynchronous
    // reset cone is needed anywhere in this module.
    always @(posedge clk) begin
        if (rst) begin
            frame_started <= 1'b0;
            reference_ready <= 1'b0;
            frame_pickup_count <= 12'd0;
            frame_operation_count <= 12'd0;
            frame_forbidden_count <= 12'd0;
            motion_pickup <= 8'd0;
            motion_operation <= 8'd0;
            motion_forbidden <= 8'd0;
            motion_global <= 8'd0;
            sample_valid_d <= 1'b0;
            sample_addr_d <= 16'd0;
            gray_now_d <= 8'd0;
            pixel_threshold_d <= 8'd0;
            in_pickup_d <= 1'b0;
            in_operation_d <= 1'b0;
            in_forbidden_d <= 1'b0;
            in_any_roi_d <= 1'b0;
        end else begin
            // Capture the next sample and its region decode.
            sample_valid_d    <= sample_valid;
            sample_addr_d     <= safe_sample_addr;
            gray_now_d        <= gray_now;
            pixel_threshold_d <= pixel_threshold;
            in_pickup_d       <= in_pickup;
            in_operation_d    <= in_operation;
            in_forbidden_d    <= in_forbidden;
            in_any_roi_d      <= in_any_roi;

            if (sof) begin
                // The first complete frame only fills previous_frame. Starting
                // with the next frame every sample has a valid reference.
                if (!frame_started) begin
                    frame_started <= 1'b1;
                end else if (!reference_ready) begin
                    reference_ready <= 1'b1;
                end else begin
                    motion_pickup <= smooth_score(motion_pickup, raw_pickup);
                    motion_operation <= smooth_score(motion_operation, raw_operation);
                    motion_forbidden <= smooth_score(motion_forbidden, raw_forbidden);
                    // Global is a summary of the three real ROI scores. It is
                    // deliberately not a fourth accumulator or feedback path.
                    motion_global <= smooth_score(motion_global, raw_global);
                end

                frame_pickup_count <= 12'd0;
                frame_operation_count <= 12'd0;
                frame_forbidden_count <= 12'd0;
            end else if (changed_pixel) begin
                if (in_pickup_d) begin
                    if (frame_pickup_count != 12'hfff)
                        frame_pickup_count <= frame_pickup_count + 12'd1;
                end else if (in_operation_d) begin
                    if (frame_operation_count != 12'hfff)
                        frame_operation_count <= frame_operation_count + 12'd1;
                end else if (in_forbidden_d) begin
                    if (frame_forbidden_count != 12'hfff)
                        frame_forbidden_count <= frame_forbidden_count + 12'd1;
                end
            end
        end
    end

endmodule
