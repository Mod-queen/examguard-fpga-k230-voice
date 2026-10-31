`timescale 1ns/1ps

// ExamGuard health monitor (50 MHz domain). Original project implementation.
//
// Turns "no alarm" vs "the link/input failed" into an explicit, reportable
// state so a quiet dashboard is not confused with a healthy system:
//   bit0 CAMERA_FROZEN  no video frame for CAMERA_FROZEN_S seconds
//   bit1 K230_SILENT    no K230 result frame for K230_SILENT_S seconds
//   bit2 EVIDENCE_BUSY  an evidence window is currently being read out
//   bit3 OVERRUN_SEEN   an event was dropped because a window was in progress
//
// overrun_count is a saturating counter of dropped events; the OVERRUN_SEEN
// flag is sticky until reset. All timing derives from the external tick_1s so
// the module has no second clock and is trivially testable.
module health_monitor #(
    parameter integer CAMERA_FROZEN_S = 3,
    parameter integer K230_SILENT_S   = 5
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        tick_1s,
    input  wire        camera_frame_pulse,
    input  wire        k230_pulse,
    input  wire        evidence_busy,
    input  wire        overrun_pulse,
    output reg  [7:0]  health_flags,
    output reg  [15:0] overrun_count,
    output reg  [15:0] camera_silent_s,
    output reg  [15:0] k230_silent_s
);
    localparam [7:0] F_CAMERA_FROZEN = 8'h01;
    localparam [7:0] F_K230_SILENT   = 8'h02;
    localparam [7:0] F_EVIDENCE_BUSY = 8'h04;
    localparam [7:0] F_OVERRUN_SEEN  = 8'h08;

    reg camera_seen, k230_seen;
    reg overrun_seen;

    function [15:0] sat_inc;
        input [15:0] value;
        begin
            sat_inc = (value == 16'hFFFF) ? value : value + 16'd1;
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            camera_seen     <= 1'b0;
            k230_seen       <= 1'b0;
            overrun_seen    <= 1'b0;
            overrun_count   <= 16'd0;
            camera_silent_s <= 16'd0;
            k230_silent_s   <= 16'd0;
            health_flags    <= 8'd0;
        end else begin
            if (camera_frame_pulse) camera_seen <= 1'b1;
            if (k230_pulse)         k230_seen   <= 1'b1;
            if (overrun_pulse) begin
                overrun_seen  <= 1'b1;
                overrun_count <= sat_inc(overrun_count);
            end

            if (tick_1s) begin
                // One-second window: reset the gap when a pulse arrived, else grow it.
                if (camera_seen) camera_silent_s <= 16'd0;
                else camera_silent_s <= sat_inc(camera_silent_s);
                if (k230_seen) k230_silent_s <= 16'd0;
                else k230_silent_s <= sat_inc(k230_silent_s);
                camera_seen <= 1'b0;
                k230_seen   <= 1'b0;
            end

            health_flags <= 8'd0;
            if (camera_silent_s >= CAMERA_FROZEN_S) health_flags[0] <= 1'b1;
            if (k230_silent_s  >= K230_SILENT_S)    health_flags[1] <= 1'b1;
            if (evidence_busy)                      health_flags[2] <= 1'b1;
            if (overrun_seen)                       health_flags[3] <= 1'b1;
        end
    end
endmodule
