`timescale 1ns/1ps
module display_pipeline_contract_tb;
 reg clk=0,rst=1,in_hs=0,in_vs=0,in_de=0;reg [23:0] in_rgb=0;
 wire out_hs,out_vs,out_de;wire [23:0]out_rgb;
 display_output_pipeline dut(.*);
 reg [26:0] previous=0;integer i,checks=0;
 initial begin
  for(i=0;i<4096;i=i+1)begin
   #4;clk=0;rst=(i<3 || i%997==0);in_rgb=(24'h35a71f*i)^24'ha0593c;
   in_hs=i%165<12;in_vs=i%1650<330;in_de=i%165>=35 && i%165<163;
   #1;if({out_rgb,out_hs,out_vs,out_de}!==previous && i>0)$fatal(1,"Output changed without pixel edge");
   #4;clk=1;previous=rst?27'd0:{in_rgb,in_hs,in_vs,in_de};
   #1;if({out_rgb,out_hs,out_vs,out_de}!==previous)$fatal(1,"RGB/control alignment or reset failed");
   checks=checks+1;
  end
  if(checks!=4096)$fatal(1,"coverage");
  $display("PASS: display_pipeline_contract_tb 4096 aligned samples, blanking, sync pulses, repeated reset, no inter-edge change");$finish;
 end
endmodule
