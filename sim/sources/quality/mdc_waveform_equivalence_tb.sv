`timescale 1ns/1ps
module mdc_equivalence_case #(parameter S=50000000, F=2000, N=30000)(output reg done=0);
  reg clk=0,rst_n=0;
  always #5 clk=~clk;
  tri mdio_new,mdio_old;
  pullup(mdio_new);pullup(mdio_old);
  wire mdc_new,mdc_old,phy_new,phy_old;
  phy_reg_config #(.SYS_CLOCK(S),.MDC_CLOCK(F),.RST_HOLD(3),.GO_CNT(7),.CNT_MAX(15),.SETTLE_MAX(8)) dut
    (.clk(clk),.rst_n(rst_n),.mdc(mdc_new),.mdio(mdio_new),.phy_rst_n(phy_new));
  phy_reg_config_reference #(.SYS_CLOCK(S),.MDC_CLOCK(F),.RST_HOLD(3),.GO_CNT(7),.CNT_MAX(15),.SETTLE_MAX(8)) ref_dut
    (.clk(clk),.rst_n(rst_n),.mdc(mdc_old),.mdio(mdio_old),.phy_rst_n(phy_old));
  integer cycles=0,edges=0;
  reg last=0;
  always @(posedge clk) begin
    #1;
    if(cycles>0 && (mdc_new!==mdc_old || phy_new!==phy_old))
      $fatal(1,"MDC mismatch S=%0d F=%0d cycle=%0d",S,F,cycles);
    if(cycles>0 && mdc_new!==last) edges=edges+1;
    last=mdc_new;cycles=cycles+1;
  end
  initial begin
    #17;rst_n=1;
    repeat(N) @(negedge clk);
    #2;rst_n=0;
    repeat(4) @(negedge clk);
    #3;rst_n=1;
    repeat(N) @(negedge clk);
    #2;rst_n=0;
    repeat(4) @(negedge clk);
    if(edges<4)$fatal(1,"No MDC activity");
    done=1;
  end
endmodule
module mdc_waveform_equivalence_tb;
  wire a,b,c,d;
  mdc_equivalence_case default_case(a);
  mdc_equivalence_case #(.S(8),.F(2),.N(77)) smallest_case(b);
  mdc_equivalence_case #(.S(16),.F(2),.N(121)) two_case(c);
  mdc_equivalence_case #(.S(80),.F(3),.N(257)) rounded_case(d);
  initial begin
    wait(a&&b&&c&&d);
    $display("PASS: mdc_waveform_equivalence_tb four divisors, default period, asynchronous reset and restart");$finish;
  end
  initial begin #10000000;$fatal(1,"timeout");end
endmodule
