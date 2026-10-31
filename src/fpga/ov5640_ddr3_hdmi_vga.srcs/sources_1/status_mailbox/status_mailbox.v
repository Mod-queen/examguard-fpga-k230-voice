`timescale 1ns/1ps

// A one-entry mailbox for transferring a coherent status snapshot between
// unrelated clock domains. The source bus remains stable until the next
// source update, while the toggle is synchronized into the destination.
module status_mailbox (
    input         src_clk,
    input         src_rst,
    input         src_valid,
    input  [31:0] src_frame_id,
    input  [3:0]  src_stage_id,
    input  [3:0]  src_risk_level,
    input  [3:0]  src_zone_id,
    input  [31:0] src_timestamp,
    input  [7:0]  src_event_code,
    input  [7:0]  src_event_seq,
    input  [7:0]  src_motion_pickup,
    input  [7:0]  src_motion_operation,
    input  [7:0]  src_motion_forbidden,
    input         dst_clk,
    input         dst_rst,
    output reg    dst_valid,
    output reg [31:0] dst_frame_id,
    output reg [3:0]  dst_stage_id,
    output reg [3:0]  dst_risk_level,
    output reg [3:0]  dst_zone_id,
    output reg [31:0] dst_timestamp,
    output reg [7:0]  dst_event_code,
    output reg [7:0]  dst_event_seq,
    output reg [7:0]  dst_motion_pickup,
    output reg [7:0]  dst_motion_operation,
    output reg [7:0]  dst_motion_forbidden
);

    reg [31:0] src_frame_id_reg;
    reg [3:0]  src_stage_id_reg;
    reg [3:0]  src_risk_level_reg;
    reg [3:0]  src_zone_id_reg;
    reg [31:0] src_timestamp_reg;
    reg [7:0]  src_event_code_reg;
    reg [7:0]  src_event_seq_reg;
    reg [7:0]  src_motion_pickup_reg;
    reg [7:0]  src_motion_operation_reg;
    reg [7:0]  src_motion_forbidden_reg;
    reg        src_toggle;

    (* ASYNC_REG = "TRUE" *) reg dst_toggle_meta;
    (* ASYNC_REG = "TRUE" *) reg dst_toggle_sync;
    reg dst_toggle_seen;

    always @(posedge src_clk) begin
        if (src_rst) begin
            src_frame_id_reg          <= 32'd0;
            src_stage_id_reg          <= 4'd0;
            src_risk_level_reg        <= 4'd0;
            src_zone_id_reg           <= 4'd0;
            src_timestamp_reg        <= 32'd0;
            src_event_code_reg        <= 8'd0;
            src_event_seq_reg         <= 8'd0;
            src_motion_pickup_reg     <= 8'd0;
            src_motion_operation_reg  <= 8'd0;
            src_motion_forbidden_reg  <= 8'd0;
            src_toggle                 <= 1'b0;
        end else if (src_valid) begin
            src_frame_id_reg          <= src_frame_id;
            src_stage_id_reg          <= src_stage_id;
            src_risk_level_reg        <= src_risk_level;
            src_zone_id_reg           <= src_zone_id;
            src_timestamp_reg         <= src_timestamp;
            src_event_code_reg        <= src_event_code;
            src_event_seq_reg         <= src_event_seq;
            src_motion_pickup_reg     <= src_motion_pickup;
            src_motion_operation_reg  <= src_motion_operation;
            src_motion_forbidden_reg  <= src_motion_forbidden;
            src_toggle                <= ~src_toggle;
        end
    end

    always @(posedge dst_clk) begin
        if (dst_rst) begin
            dst_toggle_meta         <= 1'b0;
            dst_toggle_sync         <= 1'b0;
            dst_toggle_seen         <= 1'b0;
            dst_valid               <= 1'b0;
            dst_frame_id           <= 32'd0;
            dst_stage_id           <= 4'd0;
            dst_risk_level         <= 4'd0;
            dst_zone_id            <= 4'd0;
            dst_timestamp          <= 32'd0;
            dst_event_code         <= 8'd0;
            dst_event_seq          <= 8'd0;
            dst_motion_pickup      <= 8'd0;
            dst_motion_operation   <= 8'd0;
            dst_motion_forbidden   <= 8'd0;
        end else begin
            dst_toggle_meta <= src_toggle;
            dst_toggle_sync <= dst_toggle_meta;
            dst_valid       <= 1'b0;

            if (dst_toggle_sync != dst_toggle_seen) begin
                dst_toggle_seen        <= dst_toggle_sync;
                dst_frame_id           <= src_frame_id_reg;
                dst_stage_id           <= src_stage_id_reg;
                dst_risk_level         <= src_risk_level_reg;
                dst_zone_id            <= src_zone_id_reg;
                dst_timestamp          <= src_timestamp_reg;
                dst_event_code         <= src_event_code_reg;
                dst_event_seq          <= src_event_seq_reg;
                dst_motion_pickup      <= src_motion_pickup_reg;
                dst_motion_operation   <= src_motion_operation_reg;
                dst_motion_forbidden   <= src_motion_forbidden_reg;
                dst_valid              <= 1'b1;
            end
        end
    end

endmodule
