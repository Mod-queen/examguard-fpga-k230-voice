`timescale 1ns/1ps

module gmii_rgmii_contract_tb;
 reg gmii_tx_clk=0,reset_n=0;always #4 gmii_tx_clk=~gmii_tx_clk;
 reg [7:0] gmii_txd=0;reg gmii_txen=0,gmii_txer=0;
 wire rgmii_tx_clk,rgmii_txen;wire [3:0] rgmii_txd;
 gmii_to_rgmii dut(.*);
 integer i;reg [7:0] expected;reg en,er;
 initial begin
  repeat(20) @(negedge gmii_tx_clk);reset_n=1;
  for(i=0;i<300;i=i+1) begin
   #1;expected=$random;en=i%5!=0;er=i%7==0;
   gmii_txd=expected;gmii_txen=en;gmii_txer=er;
   @(posedge gmii_tx_clk);#0.1;
   if(rgmii_txd!==expected[3:0] || rgmii_txen!==en || rgmii_tx_clk!==1) $fatal(1,"FAIL: RGMII rising nibble/control/clock");
   @(negedge gmii_tx_clk);#0.1;
   if(rgmii_txd!==expected[7:4] || rgmii_txen!==(en^er) || rgmii_tx_clk!==0) $fatal(1,"FAIL: RGMII falling nibble/XOR/clock");
  end
  reset_n=0;repeat(2) @(posedge gmii_tx_clk);#0.1;
  if(rgmii_txd || rgmii_txen || rgmii_tx_clk) $fatal(1,"FAIL: RGMII reset");
  $display("PASS: gmii_rgmii_contract actual UNISIM ODDR/300 random bytes/both edges/TX_EN XOR TX_ER/forwarded clock/reset");$finish;
 end
 initial begin #50000;$fatal(1,"FAIL: RGMII timeout");end
endmodule
