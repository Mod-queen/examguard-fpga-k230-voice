`timescale 1ns/1ps
module history_startup_gate_tb;
    reg clk=0,rst=1,sof=0,time_valid=0;
    reg [31:0] age_cycles=0;
    wire sample_open,armed;
    always #7 clk=~clk;
    history_startup_gate #(.MAX_AGE_CYCLES(4)) dut(.*);
    task automatic frame(input integer valid_time,input integer age,input integer expected_open);
        begin
            @(negedge clk);sof=1;time_valid=valid_time;age_cycles=age;#1;
            if(sample_open!==1'(expected_open)) $fatal(1,"FAIL: startup SOF qualification");
            @(negedge clk);sof=0;
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        frame(0,0,0);frame(1,5,0);
        if(armed) $fatal(1,"FAIL: armed on unknown/stale");
        frame(1,4,1);
        if(!armed || !sample_open) $fatal(1,"FAIL: equality boundary not armed");
        frame(0,0,1);frame(1,5,1); // runtime bad time must reach sampler, never hidden
        rst=1;@(negedge clk);#1;
        if(armed || sample_open) $fatal(1,"FAIL: reset did not close startup");
        rst=0;frame(0,0,0);frame(1,0,1);
        $display("PASS: history_startup_gate unknown/stale/start-boundary/runtime-fault/reset");$finish;
    end
endmodule
