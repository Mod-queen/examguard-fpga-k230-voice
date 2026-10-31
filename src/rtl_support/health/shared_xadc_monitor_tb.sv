`timescale 1ns/1ps
module shared_xadc_monitor_tb;
    reg clk=0,rst=1;always #2.5 clk=~clk;
    wire [11:0] temperature;wire [96:0] monitor;
    shared_xadc_monitor dut(.*);
    defparam dut.xadc.SIM_MONITOR_FILE="D:/fpga_race/docs/baselines/xadc_sim_analog_20261021.txt";
    initial begin
        repeat(10) @(negedge clk);rst=0;
        wait(monitor[96]);#1;
        if(monitor[15:0]<37000 || monitor[15:0]>40000 ||
            monitor[31:16]<21000 || monitor[31:16]>22500 ||
            monitor[47:32]<38000 || monitor[47:32]>40500 ||
            monitor[63:48]<21000 || monitor[63:48]>22500)
            $fatal(1,"FAIL: primitive sequencer channels differ %h",monitor);
        if(temperature!=monitor[15:4]) $fatal(1,"FAIL: MIG temperature diverged");
        $display("PASS: shared_xadc_monitor real UNISIM TEMP/INT/AUX/BRAM scan=%h",monitor);$finish;
    end
    initial begin #2000000;$fatal(1,"FAIL: shared XADC primitive no valid snapshot eos=%b state=%0d drdy=%b seqmode=%h",dut.eos,dut.reader.state,dut.drdy,dut.xadc.INIT_41);end
endmodule
