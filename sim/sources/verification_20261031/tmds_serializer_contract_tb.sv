`timescale 1ns/1ps
module tmds_serializer_contract_tb;
 reg clkx5=0;always #2 clkx5=~clkx5;
 reg [9:0] datain_0=10'h123,datain_1=10'h2a5,datain_2=10'h0f0,datain_3=10'h31c;
 wire dataout_0_p,dataout_0_n,dataout_1_p,dataout_1_n,dataout_2_p,dataout_2_n,dataout_3_p,dataout_3_n;
 serdes_4b_10to1 dut(.*);
 integer cycle=0,bit_index,k,checks=0;reg checking=0;
 always @(posedge clkx5)begin
  bit_index=2*((cycle+5)%5);#0.3;
  if(checking)begin
   if({dataout_3_p,dataout_2_p,dataout_1_p,dataout_0_p}!=={datain_3[bit_index],datain_2[bit_index],datain_1[bit_index],datain_0[bit_index]})$fatal(1,"FAIL: serializer rising bits cycle=%0d index=%0d",cycle,bit_index);
   if({dataout_3_n,dataout_2_n,dataout_1_n,dataout_0_n}!==~{dataout_3_p,dataout_2_p,dataout_1_p,dataout_0_p})$fatal(1,"FAIL: differential pair");
   checks=checks+4;
  end
  cycle=cycle+1;
 end
 always @(negedge clkx5)begin #0.3;
  if(checking)begin
   if({dataout_3_p,dataout_2_p,dataout_1_p,dataout_0_p}!=={datain_3[bit_index+1],datain_2[bit_index+1],datain_1[bit_index+1],datain_0[bit_index+1]})$fatal(1,"FAIL: serializer falling bits");
   checks=checks+4;
  end
 end
 initial begin
  repeat(50)@(negedge clkx5);
  for(k=0;k<40;k=k+1)begin
   #0.5;checking=0;datain_0=$random;datain_1=$random;datain_2=$random;datain_3=$random;
   repeat(10)@(negedge clkx5);#0.5;checking=1;repeat(10)@(negedge clkx5);
  end
  #0.5;checking=0;
  if(checks<3000)$fatal(1,"FAIL: serializer check count");
  $display("PASS: tmds_serializer_contract actual UNISIM ODDR/OBUFDS/four lanes/40 patterns/LSB-first ten bits/both edges/differential polarity bits=%0d",checks);$finish;
 end
 initial begin #100000;$fatal(1,"FAIL: serializer timeout");end
endmodule
