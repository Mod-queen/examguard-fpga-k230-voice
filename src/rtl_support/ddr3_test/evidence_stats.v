`timescale 1ns/1ps

// Evidence-path statistics (C16). Original project design. Saturating counters
// so a long run never wraps, plus sticky fault flags. Purely observational: it
// consumes one-cycle pulses from the evidence ring / DMAs and exposes counts
// for the host report. No data path is affected.
module evidence_stats #(
    parameter integer COUNTER_WIDTH = 32
)(
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    frame_committed,   // a frame landed in the ring
    input  wire                    window_captured,   // a locked window read out
    input  wire                    overrun_pulse,     // busy-time event overlapped
    input  wire                    pending_served,    // a queued event was served
    input  wire                    beats_written,     // DMA wrote a beat
    input  wire                    beats_read,        // DMA read a beat
    output reg  [COUNTER_WIDTH-1:0] frames_written,
    output reg  [COUNTER_WIDTH-1:0] windows_captured,
    output reg  [COUNTER_WIDTH-1:0] overruns,
    output reg  [COUNTER_WIDTH-1:0] pendings_served,
    output reg  [COUNTER_WIDTH-1:0] total_beats_written,
    output reg  [COUNTER_WIDTH-1:0] total_beats_read,
    output reg  [7:0]               fault_flags
);
    localparam [COUNTER_WIDTH-1:0] MAXV = {COUNTER_WIDTH{1'b1}};

    function [COUNTER_WIDTH-1:0] sat_inc;
        input [COUNTER_WIDTH-1:0] v;
        begin sat_inc = (v == MAXV) ? v : v + 1'b1; end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            frames_written     <= {COUNTER_WIDTH{1'b0}};
            windows_captured   <= {COUNTER_WIDTH{1'b0}};
            overruns           <= {COUNTER_WIDTH{1'b0}};
            pendings_served    <= {COUNTER_WIDTH{1'b0}};
            total_beats_written<= {COUNTER_WIDTH{1'b0}};
            total_beats_read   <= {COUNTER_WIDTH{1'b0}};
            fault_flags        <= 8'd0;
        end else begin
            if (frame_committed)  frames_written  <= sat_inc(frames_written);
            if (window_captured)  windows_captured<= sat_inc(windows_captured);
            if (pending_served)   pendings_served <= sat_inc(pendings_served);
            if (beats_written)    total_beats_written <= sat_inc(total_beats_written);
            if (beats_read)       total_beats_read    <= sat_inc(total_beats_read);
            if (overrun_pulse) begin
                overruns <= sat_inc(overruns);
                fault_flags[0] <= 1'b1;   // sticky overrun
            end
        end
    end
endmodule
