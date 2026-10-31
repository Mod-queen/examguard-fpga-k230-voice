`timescale 1ns/1ps

module workflow_fsm #(
    parameter ACTIVE_THRESHOLD = 8'd8,
    parameter PICKUP_TIMEOUT_FRAMES = 12'd900,
    parameter OPERATION_QUIET_FRAMES = 12'd2,
    parameter DONE_HOLD_FRAMES = 12'd30
) (
    input         clk,
    input         rst,
    input         sof,
    input  [7:0]  motion_pickup,
    input  [7:0]  motion_operation,
    input  [7:0]  motion_forbidden,
    output reg [3:0] stage_id,
    output reg [3:0] risk_level,
    output reg [3:0] zone_id,
    output reg [7:0] event_code
);

    localparam STAGE_IDLE      = 4'd0;
    localparam STAGE_PICKUP    = 4'd1;
    localparam STAGE_OPERATION = 4'd2;
    localparam STAGE_DONE      = 4'd3;

    localparam ZONE_NONE      = 4'd0;
    localparam ZONE_PICKUP    = 4'd1;
    localparam ZONE_OPERATION = 4'd2;
    localparam ZONE_FORBIDDEN = 4'd3;

    localparam RISK_NORMAL = 4'd0;
    localparam RISK_WARNING = 4'd1;
    localparam RISK_ALARM = 4'd2;

    localparam EVENT_NONE              = 8'h00;
    localparam EVENT_PICKUP_ENTER      = 8'h01;
    localparam EVENT_OPERATION_ENTER   = 8'h02;
    localparam EVENT_WORKFLOW_DONE     = 8'h03;
    localparam EVENT_WRONG_OPERATION   = 8'h21;
    localparam EVENT_WRONG_PICKUP      = 8'h22;
    localparam EVENT_PICKUP_TIMEOUT    = 8'h31;
    localparam EVENT_FORBIDDEN_ENTRY   = 8'h40;

    reg [2:0] state;
    reg [11:0] stage_timer;
    reg [11:0] quiet_timer;
    reg [11:0] done_timer;

    wire pickup_active = motion_pickup >= ACTIVE_THRESHOLD;
    wire operation_active = motion_operation >= ACTIVE_THRESHOLD;
    wire forbidden_active = motion_forbidden >= ACTIVE_THRESHOLD;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= STAGE_IDLE;
            stage_timer <= 12'd0;
            quiet_timer <= 12'd0;
            done_timer <= 12'd0;
            stage_id <= STAGE_IDLE;
            risk_level <= RISK_NORMAL;
            zone_id <= ZONE_NONE;
            event_code <= EVENT_NONE;
        end else if (sof) begin
            // Events are one-frame pulses. Risk and zone describe the frame
            // that caused the event and remain alarm-level while forbidden
            // activity is present.
            event_code <= EVENT_NONE;
            risk_level <= RISK_NORMAL;
            zone_id <= ZONE_NONE;

            if (forbidden_active) begin
                risk_level <= RISK_ALARM;
                zone_id <= ZONE_FORBIDDEN;
                event_code <= EVENT_FORBIDDEN_ENTRY;
            end else begin
                case (state)
                    STAGE_IDLE: begin
                        stage_timer <= 12'd0;
                        quiet_timer <= 12'd0;
                        done_timer <= 12'd0;

                        if (operation_active) begin
                            risk_level <= RISK_ALARM;
                            zone_id <= ZONE_OPERATION;
                            event_code <= EVENT_WRONG_OPERATION;
                        end else if (pickup_active) begin
                            state <= STAGE_PICKUP;
                            stage_id <= STAGE_PICKUP;
                            zone_id <= ZONE_PICKUP;
                            event_code <= EVENT_PICKUP_ENTER;
                        end else begin
                            stage_id <= STAGE_IDLE;
                        end
                    end

                    STAGE_PICKUP: begin
                        done_timer <= 12'd0;
                        if (stage_timer != 12'hfff)
                            stage_timer <= stage_timer + 12'd1;

                        if (operation_active) begin
                            state <= STAGE_OPERATION;
                            stage_id <= STAGE_OPERATION;
                            stage_timer <= 12'd0;
                            quiet_timer <= 12'd0;
                            zone_id <= ZONE_OPERATION;
                            event_code <= EVENT_OPERATION_ENTER;
                        end else if (pickup_active) begin
                            zone_id <= ZONE_PICKUP;
                            quiet_timer <= 12'd0;
                        end else if (stage_timer >= PICKUP_TIMEOUT_FRAMES) begin
                            risk_level <= RISK_WARNING;
                            event_code <= EVENT_PICKUP_TIMEOUT;
                        end else begin
                            quiet_timer <= quiet_timer + 12'd1;
                        end
                    end

                    STAGE_OPERATION: begin
                        stage_timer <= 12'd0;
                        done_timer <= 12'd0;

                        if (operation_active) begin
                            zone_id <= ZONE_OPERATION;
                            quiet_timer <= 12'd0;
                        end else if (pickup_active) begin
                            risk_level <= RISK_WARNING;
                            zone_id <= ZONE_PICKUP;
                            event_code <= EVENT_WRONG_PICKUP;
                            quiet_timer <= 12'd0;
                        end else if ((quiet_timer + 12'd1) >= OPERATION_QUIET_FRAMES) begin
                            state <= STAGE_DONE;
                            stage_id <= STAGE_DONE;
                            quiet_timer <= 12'd0;
                            event_code <= EVENT_WORKFLOW_DONE;
                        end else begin
                            quiet_timer <= quiet_timer + 12'd1;
                        end
                    end

                    STAGE_DONE: begin
                        stage_timer <= 12'd0;
                        quiet_timer <= 12'd0;
                        if (pickup_active) begin
                            state <= STAGE_PICKUP;
                            stage_id <= STAGE_PICKUP;
                            done_timer <= 12'd0;
                            zone_id <= ZONE_PICKUP;
                            event_code <= EVENT_PICKUP_ENTER;
                        end else if (operation_active) begin
                            risk_level <= RISK_ALARM;
                            zone_id <= ZONE_OPERATION;
                            event_code <= EVENT_WRONG_OPERATION;
                        end else if ((done_timer + 12'd1) >= DONE_HOLD_FRAMES) begin
                            state <= STAGE_IDLE;
                            stage_id <= STAGE_IDLE;
                            done_timer <= 12'd0;
                        end else begin
                            done_timer <= done_timer + 12'd1;
                        end
                    end

                    default: begin
                        state <= STAGE_IDLE;
                        stage_id <= STAGE_IDLE;
                        stage_timer <= 12'd0;
                        quiet_timer <= 12'd0;
                        done_timer <= 12'd0;
                    end
                endcase
            end
        end
    end

endmodule
