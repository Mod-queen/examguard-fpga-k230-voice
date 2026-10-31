`timescale 1ns/1ps

module motion_detect_tb;

    reg         clk;
    reg         rst;
    reg  [23:0] pixel_in;
    reg  [11:0] x;
    reg  [11:0] y;
    reg         de;
    reg         sof;
    wire [7:0]  motion_pickup;
    wire [7:0]  motion_operation;
    wire [7:0]  motion_forbidden;
    wire [7:0]  motion_global;

    motion_detect #(
        .SAMPLE_SHIFT(2),
        .GRID_WIDTH(4),
        .GRID_HEIGHT(3),
        .SCORE_SHIFT(0),
        .FRAME_NOISE_FLOOR(8'd0),
        .GLOBAL_ACTIVITY_THRESHOLD(8'd1)
    ) dut (
        .clk(clk),
        .rst(rst),
        .pixel_in(pixel_in),
        .x(x),
        .y(y),
        .de(de),
        .sof(sof),
        .roi_pickup_x0(12'd0),
        .roi_pickup_y0(12'd0),
        .roi_pickup_x1(12'd16),
        .roi_pickup_y1(12'd4),
        .roi_operation_x0(12'd0),
        .roi_operation_y0(12'd4),
        .roi_operation_x1(12'd16),
        .roi_operation_y1(12'd8),
        .roi_forbidden_x0(12'd0),
        .roi_forbidden_y0(12'd8),
        .roi_forbidden_x1(12'd16),
        .roi_forbidden_y1(12'd12),
        .thr_pickup(8'd8),
        .thr_operation(8'd8),
        .thr_forbidden(8'd8),
        .motion_pickup(motion_pickup),
        .motion_operation(motion_operation),
        .motion_forbidden(motion_forbidden),
        .motion_global(motion_global)
    );

    always #5 clk = ~clk;

    task drive_frame;
        input [7:0] base_gray;
        input       changed_sample;
        integer xx;
        integer yy;
        integer gray_value;
        begin
            @(negedge clk);
            sof = 1'b1;
            de = 1'b0;
            x = 12'd0;
            y = 12'd0;
            pixel_in = {base_gray, base_gray, base_gray};

            @(negedge clk);
            sof = 1'b0;
            for (yy = 0; yy < 12; yy = yy + 1) begin
                for (xx = 0; xx < 16; xx = xx + 1) begin
                    x = xx;
                    y = yy;
                    de = 1'b1;
                    if (changed_sample && xx < 4 && yy < 4)
                        pixel_in = 24'hf0_f0_f0;
                    else begin
                        // A repeatable textured scene catches the old
                        // single-background implementation's false motion.
                        gray_value = base_gray + ((xx * 3 + yy * 5) & 31);
                        pixel_in = {gray_value[7:0], gray_value[7:0], gray_value[7:0]};
                    end
                    @(negedge clk);
                end
            end
            de = 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        pixel_in = 24'd0;
        x = 12'd0;
        y = 12'd0;
        de = 1'b0;
        sof = 1'b0;

        repeat (3) @(negedge clk);
        rst = 1'b0;

        // Fill the reference frame, then verify two static frames stay quiet.
        drive_frame(8'd80, 1'b0);
        drive_frame(8'd80, 1'b0);
        drive_frame(8'd80, 1'b0);
        if (motion_global !== 8'd0 || motion_pickup !== 8'd0) begin
            $display("FAIL: static scene generated motion");
            $finish;
        end

        // Change one 4x4 sample block in pickup; the score must rise.
        drive_frame(8'd80, 1'b1);
        drive_frame(8'd80, 1'b1);
        if (motion_global == 8'd0 || motion_pickup == 8'd0) begin
            $display("FAIL: changed sample was not detected");
            $finish;
        end

        // Keep the changed frame fixed; there is no new temporal change.
        drive_frame(8'd80, 1'b1);
        if (motion_global >= 8'd2 || motion_pickup >= 8'd2) begin
            $display("FAIL: static changed scene did not settle");
            $finish;
        end

        $display("PASS: frame-difference motion detector");
        $finish;
    end

endmodule
