`timescale 1ns/1ps
module board_status_control_tb;
    reg clk=0,rst=1;always #10 clk=~clk;
    reg [7:0] switches=8'h85;
    reg config_known=1,ai_alive=0,network_qualified=0,evidence_fault=0;
    reg [31:0] configured_seat=42;
    wire straps_valid;wire [7:0] latched_switches;wire [31:0] seat_id;wire [2:0] led;
    board_status_control #(.SETTLE_CYCLES(8),.HEARTBEAT_CYCLES(5)) dut(.*);
    initial begin
        repeat(4) @(negedge clk);rst=0;wait(straps_valid);#1;
        if(latched_switches!=8'h85 || seat_id!=6) $fatal(1,"FAIL: DIP sample");
        switches=8'hff;repeat(20) @(negedge clk);
        if(seat_id!=6) $fatal(1,"FAIL: DIP changed in exam");
        ai_alive=1;network_qualified=1;#1;if(led!=7) $fatal(1,"FAIL: LED mapping");
        evidence_fault=1;repeat(5) @(negedge clk);#1;
        if(led[2]!==dut.pulse) $fatal(1,"FAIL: fault blink");
        rst=1;switches=0;repeat(4) @(negedge clk);rst=0;wait(straps_valid);#1;
        if(seat_id!=42) $fatal(1,"FAIL: config fallback");
        config_known=0;#1;if(seat_id!=1) $fatal(1,"FAIL: default seat");
        $display("PASS: board_status_control DIP startup-only/override/default/LED/blink/reset");$finish;
    end
endmodule
