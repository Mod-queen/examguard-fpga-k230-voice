`timescale 1ns/1ps
module cdc_exam_status_tb;

    reg        src_clk = 0, src_rst = 1;
    reg  [2:0] src_stage = 0;
    reg  [1:0] src_risk = 0;
    reg  [7:0] src_event = 0;
    reg        dst_clk = 0, dst_rst = 1;
    wire [2:0] dst_stage;
    wire [1:0] dst_risk;
    wire [7:0] dst_event;

    always #10 src_clk = ~src_clk;   // 50 MHz
    always #13 dst_clk = ~dst_clk;   // ~38 MHz (pixel-like)

    cdc_exam_status dut (
        .src_clk(src_clk), .src_rst(src_rst),
        .src_stage(src_stage), .src_risk(src_risk), .src_event(src_event),
        .dst_clk(dst_clk), .dst_rst(dst_rst),
        .dst_stage(dst_stage), .dst_risk(dst_risk), .dst_event(dst_event)
    );

    initial begin
        repeat (3) @(negedge src_clk);
        src_rst = 0;
        repeat (3) @(negedge dst_clk);
        dst_rst = 0;

        @(negedge src_clk);
        src_stage = 3'd3; src_risk = 2'd2; src_event = 8'h50;
        repeat (8) @(negedge dst_clk);
        if (dst_stage !== 3'd3 || dst_risk !== 2'd2 || dst_event !== 8'h50) begin
            $display("FAIL: bridge stage=%0d risk=%0d event=%02h", dst_stage, dst_risk, dst_event);
            $finish;
        end

        @(negedge src_clk);
        src_stage = 3'd5; src_risk = 2'd0; src_event = 8'h03;
        repeat (8) @(negedge dst_clk);
        if (dst_stage !== 3'd5 || dst_risk !== 2'd0 || dst_event !== 8'h03) begin
            $display("FAIL: bridge2 stage=%0d risk=%0d event=%02h", dst_stage, dst_risk, dst_event);
            $finish;
        end

        $display("PASS: cdc_exam_status");
        $finish;
    end

endmodule
