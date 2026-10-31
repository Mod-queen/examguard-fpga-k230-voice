`timescale 1ns/1ps
// Startup-only switch snapshot; no live exam reconfiguration from DIP changes.
// SW7 enables seat override, SW[6:0]+1 seat. Otherwise EEPROM seat applies.
// Three existing LEDs are repurposed only inside a future independent candidate.
module board_status_control #(
    parameter integer SETTLE_CYCLES=2500000,HEARTBEAT_CYCLES=25000000
)(
    input wire clk,rst,input wire [7:0] switches,
    input wire config_known,input wire [31:0] configured_seat,
    input wire ai_alive,network_qualified,evidence_fault,
    output reg straps_valid,output reg [7:0] latched_switches,
    output wire [31:0] seat_id,output wire [2:0] led
);
    (* ASYNC_REG="TRUE" *) reg [7:0] sw_meta,sw_sync;
    reg [31:0] settle,heartbeat;
    reg pulse;
    always @(posedge clk) begin
        if(rst) begin sw_meta<=0;sw_sync<=0;settle<=0;straps_valid<=0;latched_switches<=0;heartbeat<=0;pulse<=0;end
        else begin
            sw_meta<=switches;sw_sync<=sw_meta;
            if(!straps_valid) begin
                if(settle==SETTLE_CYCLES-1) begin straps_valid<=1;latched_switches<=sw_sync;end
                else settle<=settle+1'b1;
            end
            if(heartbeat==HEARTBEAT_CYCLES-1) begin heartbeat<=0;pulse<=!pulse;end
            else heartbeat<=heartbeat+1'b1;
        end
    end
    assign seat_id=straps_valid && latched_switches[7] ? {25'd0,latched_switches[6:0]}+32'd1 :
        config_known?configured_seat:32'd1;
    assign led={evidence_fault?pulse:1'b1,network_qualified,ai_alive};
endmodule
