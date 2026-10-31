`timescale 1ns/1ps

module alarm_output #(
    parameter WARNING_LEVEL = 4'd1,
    parameter ALARM_LEVEL = 4'd2
) (
    input  [3:0] risk_level,
    output       alarm_active,
    output       warning_active
);

    assign alarm_active = risk_level >= ALARM_LEVEL;
    assign warning_active = (risk_level >= WARNING_LEVEL) && !alarm_active;

endmodule
