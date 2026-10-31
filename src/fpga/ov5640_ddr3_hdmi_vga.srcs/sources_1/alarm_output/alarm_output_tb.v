`timescale 1ns/1ps

module alarm_output_tb;

    reg  [3:0] risk_level;
    wire       alarm_active;
    wire       warning_active;

    alarm_output dut (
        .risk_level(risk_level),
        .alarm_active(alarm_active),
        .warning_active(warning_active)
    );

    initial begin
        risk_level = 4'd0;
        #1;
        if (alarm_active || warning_active) begin
            $display("FAIL: normal risk asserted alarm");
            $finish;
        end

        risk_level = 4'd1;
        #1;
        if (alarm_active || !warning_active) begin
            $display("FAIL: warning risk was not mapped");
            $finish;
        end

        risk_level = 4'd2;
        #1;
        if (!alarm_active || warning_active) begin
            $display("FAIL: alarm risk was not mapped");
            $finish;
        end

        $display("PASS: local alarm mapping");
        $finish;
    end

endmodule
