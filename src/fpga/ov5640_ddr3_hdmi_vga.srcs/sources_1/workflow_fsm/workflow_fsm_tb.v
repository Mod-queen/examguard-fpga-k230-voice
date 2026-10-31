`timescale 1ns/1ps

module workflow_fsm_tb;

    reg clk;
    reg rst;
    reg sof;
    reg [7:0] motion_pickup;
    reg [7:0] motion_operation;
    reg [7:0] motion_forbidden;
    wire [3:0] stage_id;
    wire [3:0] risk_level;
    wire [3:0] zone_id;
    wire [7:0] event_code;

    workflow_fsm #(
        .ACTIVE_THRESHOLD(8'd8),
        .PICKUP_TIMEOUT_FRAMES(12'd3),
        .OPERATION_QUIET_FRAMES(12'd2),
        .DONE_HOLD_FRAMES(12'd2)
    ) dut (
        .clk(clk),
        .rst(rst),
        .sof(sof),
        .motion_pickup(motion_pickup),
        .motion_operation(motion_operation),
        .motion_forbidden(motion_forbidden),
        .stage_id(stage_id),
        .risk_level(risk_level),
        .zone_id(zone_id),
        .event_code(event_code)
    );

    always #5 clk = ~clk;

    task frame;
        input [7:0] pickup_value;
        input [7:0] operation_value;
        input [7:0] forbidden_value;
        begin
            @(negedge clk);
            motion_pickup = pickup_value;
            motion_operation = operation_value;
            motion_forbidden = forbidden_value;
            sof = 1'b1;
            @(negedge clk);
            sof = 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        sof = 1'b0;
        motion_pickup = 8'd0;
        motion_operation = 8'd0;
        motion_forbidden = 8'd0;

        repeat (2) @(negedge clk);
        rst = 1'b0;

        frame(8'd0, 8'd0, 8'd0);
        if (stage_id !== 4'd0 || risk_level !== 4'd0) begin
            $display("FAIL: reset/idle state");
            $finish;
        end

        frame(8'd32, 8'd0, 8'd0);
        if (stage_id !== 4'd1 || zone_id !== 4'd1 || event_code !== 8'h01) begin
            $display("FAIL: pickup entry");
            $finish;
        end

        frame(8'd0, 8'd32, 8'd0);
        if (stage_id !== 4'd2 || zone_id !== 4'd2 || event_code !== 8'h02) begin
            $display("FAIL: operation entry");
            $finish;
        end

        frame(8'd0, 8'd0, 8'd0);
        frame(8'd0, 8'd0, 8'd0);
        if (stage_id !== 4'd3 || event_code !== 8'h03) begin
            $display("FAIL: operation completion");
            $finish;
        end

        frame(8'd0, 8'd0, 8'd0);
        frame(8'd0, 8'd0, 8'd0);
        if (stage_id !== 4'd0) begin
            $display("FAIL: done hold did not return idle");
            $finish;
        end

        frame(8'd0, 8'd32, 8'd0);
        if (risk_level !== 4'd2 || zone_id !== 4'd2 || event_code !== 8'h21) begin
            $display("FAIL: skipped pickup was not alarmed");
            $finish;
        end

        frame(8'd0, 8'd0, 8'd32);
        if (risk_level !== 4'd2 || zone_id !== 4'd3 || event_code !== 8'h40) begin
            $display("FAIL: forbidden entry was not alarmed");
            $finish;
        end

        $display("PASS: workflow state machine");
        $finish;
    end

endmodule
