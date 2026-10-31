`timescale 1ns/1ps
// Count EVERY active pre-overlay video pixel. Never infer cover from motion.
module camera_black_gate #(
    parameter integer WIDTH = 1280,
    parameter integer HEIGHT = 720,
    parameter [7:0] BLACK_MAX = 8'd16,
    parameter integer BLACK_PERCENT = 98,
    parameter integer CONFIRM_FRAMES = 30,
    parameter integer RELEASE_FRAMES = 3
) (
    input wire clk, rst, sof, de,
    input wire [11:0] x, y,
    input wire [23:0] pixel,
    output reg covered,
    output reg frame_is_black,
    output reg frame_valid
);
    localparam integer PIXELS = WIDTH * HEIGHT;
    localparam integer REQUIRED = (PIXELS * BLACK_PERCENT + 99) / 100;
    reg started;
    reg [20:0] count, blacks;
    reg overflow;
    reg [15:0] streak, clear_streak;
    wire valid_pixel = de && x < WIDTH && y < HEIGHT;
    wire black_pixel = pixel[23:16] <= BLACK_MAX &&
                       pixel[15:8] <= BLACK_MAX && pixel[7:0] <= BLACK_MAX;
    wire valid_frame = started && !overflow && count == PIXELS;
    wire black_frame = valid_frame && blacks >= REQUIRED;
    always @(posedge clk) begin
        if (rst) begin
            started <= 0; count <= 0; blacks <= 0; overflow <= 0;
            streak <= 0; clear_streak <= 0; covered <= 0;
            frame_is_black <= 0; frame_valid <= 0;
        end else if (sof) begin
            frame_valid <= valid_frame;
            frame_is_black <= black_frame;
            if (!valid_frame) begin
                streak <= 0; clear_streak <= 0; covered <= 0;
            end else if (black_frame) begin
                clear_streak <= 0;
                if (streak < CONFIRM_FRAMES) streak <= streak + 1'b1;
                if (streak >= CONFIRM_FRAMES - 1) covered <= 1;
            end else begin
                streak <= 0;
                if (clear_streak < RELEASE_FRAMES) clear_streak <= clear_streak + 1'b1;
                if (clear_streak >= RELEASE_FRAMES - 1) covered <= 0;
            end
            // SOF can coincide with the first valid active pixel: keep it.
            started <= 1;
            count <= valid_pixel ? 1 : 0;
            blacks <= valid_pixel && black_pixel ? 1 : 0;
            overflow <= 0;
        end else if (valid_pixel && started) begin
            if (count < PIXELS) begin
                count <= count + 1'b1;
                if (black_pixel) blacks <= blacks + 1'b1;
            end else overflow <= 1;
        end
    end
endmodule
