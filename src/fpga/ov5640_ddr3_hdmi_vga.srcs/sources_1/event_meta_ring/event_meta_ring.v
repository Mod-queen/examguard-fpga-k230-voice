`timescale 1ns/1ps

// Fixed-size metadata evidence ring. The ring is intentionally independent
// from the video/DDR datapath: one compact record is written at a frame-rate
// cadence, then a completed alarm window can be read in chronological order.
module event_meta_ring #(
    parameter integer ADDR_WIDTH = 7,
    parameter integer PRE_SAMPLES = 32,
    parameter integer POST_SAMPLES = 32,
    parameter integer RECORD_WIDTH = 132,
    parameter integer READ_INDEX_WIDTH =
        ((PRE_SAMPLES + POST_SAMPLES + 1) < 2) ? 1 :
        $clog2(PRE_SAMPLES + POST_SAMPLES + 1)
) (
    input         clk,
    input         rst,
    input         sample_valid,
    input  [31:0] sample_frame_id,
    input  [31:0] sample_timestamp_ms,
    input  [3:0]  sample_stage_id,
    input  [3:0]  sample_risk_level,
    input  [3:0]  sample_zone_id,
    input  [7:0]  sample_event_code,
    input  [7:0]  sample_motion_pickup,
    input  [7:0]  sample_motion_operation,
    input  [7:0]  sample_motion_forbidden,
    input  [7:0]  sample_config_version,
    input  [7:0]  sample_health_flags,
    input  [7:0]  sample_event_seq,
    input         event_trigger,
    input         readout_active,
    output reg    event_busy,
    output reg    event_done,
    output reg    event_available,
    output reg    event_overrun,
    output reg [7:0] snapshot_event_seq,
    input         read_req,
    input  [READ_INDEX_WIDTH-1:0] read_index,
    output reg    read_valid,
    output reg [RECORD_WIDTH-1:0] read_data
);

    localparam integer RING_DEPTH = (1 << ADDR_WIDTH);
    localparam integer CAPTURE_LENGTH = PRE_SAMPLES + POST_SAMPLES + 1;

    // Layout, from MSB to LSB:
    // frame, timestamp_ms, stage, risk, zone, event, three scores,
    // config_version, health_flags, event_seq.
    reg [RECORD_WIDTH-1:0] record_mem [0:RING_DEPTH-1];
    reg [ADDR_WIDTH-1:0] write_ptr;
    reg [ADDR_WIDTH-1:0] snapshot_base;
    reg [READ_INDEX_WIDTH-1:0] post_remaining;

    wire [RECORD_WIDTH-1:0] sample_record = {
        sample_frame_id,
        sample_timestamp_ms,
        sample_stage_id,
        sample_risk_level,
        sample_zone_id,
        sample_event_code,
        sample_motion_pickup,
        sample_motion_operation,
        sample_motion_forbidden,
        sample_config_version,
        sample_health_flags,
        sample_event_seq
    };

    always @(posedge clk) begin
        if (rst) begin
            write_ptr        <= {ADDR_WIDTH{1'b0}};
            snapshot_base    <= {ADDR_WIDTH{1'b0}};
            post_remaining   <= {READ_INDEX_WIDTH{1'b0}};
            event_busy       <= 1'b0;
            event_done       <= 1'b0;
            event_available  <= 1'b0;
            event_overrun    <= 1'b0;
            snapshot_event_seq <= 8'd0;
            read_valid       <= 1'b0;
            read_data        <= {RECORD_WIDTH{1'b0}};
        end else begin
            event_done <= 1'b0;
            read_valid <= 1'b0;

            if (sample_valid) begin
                record_mem[write_ptr] <= sample_record;

                // An event trigger includes the current sample. PRE_SAMPLES
                // therefore selects the records immediately before it. A new
                // window may only begin when no unconsumed window is waiting
                // and no readout is in progress; otherwise the snapshot being
                // streamed to the host would be replaced mid-read.
                if (event_trigger && !event_busy && !event_available &&
                    !readout_active) begin
                    snapshot_base      <= write_ptr - PRE_SAMPLES;
                    snapshot_event_seq <= sample_event_seq;
                    event_available    <= 1'b0;
                    post_remaining     <= POST_SAMPLES;
                    if (POST_SAMPLES == 0) begin
                        event_busy      <= 1'b0;
                        event_done      <= 1'b1;
                        event_available <= 1'b1;
                    end else begin
                        event_busy <= 1'b1;
                    end
                end else if (event_trigger) begin
                    // Keep the first alarm window intact. The flag makes
                    // dropped overlapping evidence visible to the host.
                    event_overrun <= 1'b1;
                end

                if (event_busy) begin
                    if (post_remaining <= 1) begin
                        post_remaining  <= {READ_INDEX_WIDTH{1'b0}};
                        event_busy      <= 1'b0;
                        event_done      <= 1'b1;
                        event_available <= 1'b1;
                    end else begin
                        post_remaining <= post_remaining - 1'b1;
                    end
                end

                write_ptr <= write_ptr + 1'b1;
            end

            // The window is consumed as soon as a readout begins. Reads stay
            // enabled for the whole readout, and new windows are held off
            // until it finishes, so a snapshot can never change mid-stream.
            if (readout_active && event_available)
                event_available <= 1'b0;

            if (read_req && (event_available || readout_active) &&
                (read_index < CAPTURE_LENGTH)) begin
                read_data  <= record_mem[snapshot_base + read_index];
                read_valid <= 1'b1;
            end
        end
    end

endmodule
