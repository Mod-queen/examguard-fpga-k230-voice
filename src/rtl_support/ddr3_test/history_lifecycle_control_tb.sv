`timescale 1ns/1ps
module history_lifecycle_control_tb;
    reg clk=0,transport_rst=1,axi_idle=0,local_cancelled=0,clock_enable=1;
    always #10 if(clock_enable) clk=~clk;
    wire client_transport_rst,source_epoch_rst;
    history_lifecycle_control dut(.*);
    initial begin
        repeat(4) @(negedge clk);transport_rst=0;
        repeat(12) @(negedge clk);
        if(!client_transport_rst || !source_epoch_rst) $fatal(1,"FAIL: opened with old AXI active");
        axi_idle=1;wait(!client_transport_rst);@(negedge clk);
        axi_idle=0;repeat(30) @(negedge clk);
        if(client_transport_rst || source_epoch_rst) $fatal(1,"FAIL: ordinary DMA activity reset source");
        local_cancelled=1;repeat(300) @(negedge clk);
        if(!source_epoch_rst || client_transport_rst) $fatal(1,"FAIL: local cancel not held / implicit retry");
        // A sub-cycle transport pulse while stopped must latch reset; releasing
        // the pulse without control clock may not reopen the client.
        clock_enable=0;#13;transport_rst=1;#2;transport_rst=0;#200;
        if(!client_transport_rst) $fatal(1,"FAIL: missed short reset while stopped");
        clock_enable=1;local_cancelled=0;repeat(10) @(negedge clk);
        if(!client_transport_rst) $fatal(1,"FAIL: reset reopened before drain");
        axi_idle=1;wait(!client_transport_rst);#1;
        if(source_epoch_rst) $fatal(1,"FAIL: source not released after fresh reset/drain");
        $display("PASS: history_lifecycle_control drain/start/run/local-halt/short-reset/stopped-clock");$finish;
    end
    initial begin #50000;$fatal(1,"FAIL: lifecycle timeout");end
endmodule
