`timescale 1ns/1ps
module ready_source_contract_tb;
  reg clk=0,run=1,reset_n=0,raw_rst=1,init_done=0;
  always #5 if(run)clk=~clk;
  wire ready;
  ready_source_extracted dut(clk,reset_n,raw_rst,init_done,ready);
  task tick;begin @(posedge clk);#1;end endtask
  initial begin
    #2;reset_n=1;tick();
    if(ready!==0)$fatal(1,"held reset");
    @(negedge clk);raw_rst=0;init_done=1;
    #2;if(ready!==0)$fatal(1,"not registered");
    tick();if(ready!==1)$fatal(1,"source did not register");
    @(negedge clk);init_done=0;#1;init_done=1;#1;
    if(ready!==1)$fatal(1,"combinational glitch propagated");
    tick();if(ready!==1)$fatal(1,"glitch affected registered output");
    @(negedge clk);raw_rst=1;tick();
    if(ready!==0)$fatal(1,"MIG reset failed");
    @(negedge clk);raw_rst=0;tick();
    if(ready!==1)$fatal(1,"restart failed");
    @(negedge clk);run=0;#2;reset_n=0;#1;
    if(ready!==0)$fatal(1,"global reset must assert with stopped UI clock");
    #2;reset_n=1;#11;if(ready!==0)$fatal(1,"release without UI clock");
    run=1;tick();if(ready!==1)$fatal(1,"restart after stopped clock");
    @(negedge clk);init_done=0;tick();
    if(ready!==0)$fatal(1,"readiness lost");
    $display("PASS: ready_source_contract_tb readiness, glitch, MIG reset, stopped clock and restart");$finish;
  end
  initial begin #2000;$fatal(1,"timeout");end
endmodule
