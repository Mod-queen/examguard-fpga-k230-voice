`timescale 1ns/1ps
// Wrapper wiring is checked in addition to the independent encoder and
// serializer tests. Uses real UNISIM ODDR/OBUFDS, not a serializer substitute.
module dvi_encoder_contract_tb;
 reg pixelclk=0,pixelclk5x=0,rst_p=1,hsync=0,vsync=0,de=0;
 reg [7:0] blue_din=0,green_din=0,red_din=0;
 always #10 pixelclk=~pixelclk;
 always #2 pixelclk5x=~pixelclk5x;
 wire tmds_clk_p,tmds_clk_n;wire [2:0] tmds_data_p,tmds_data_n;
 dvi_encoder dut(.*);
 reg [9:0] loaded[0:3],active[0:3];
 reg [23:0] rgb_history[0:1];reg [1:0] ctl_history[0:1];reg [1:0] de_history=0;
 integer cycle=0,bit_index,lane,k,j,pixels=0,serial_checks=0,decode_checks=0;
 reg checking=0;reg [7:0] q,decoded;reg [9:0] word,control_word;
 always @(posedge pixelclk5x)begin
  bit_index=2*(cycle%5);
  if(cycle%5==0)for(lane=0;lane<4;lane=lane+1)active[lane]=loaded[lane];
  if(cycle%5==4)begin loaded[0]=dut.blue;loaded[1]=dut.green;loaded[2]=dut.red;loaded[3]=10'b1111100000;end
  #0.3;
  if(checking)begin
   if({tmds_clk_p,tmds_data_p}!=={active[3][bit_index],active[2][bit_index],active[1][bit_index],active[0][bit_index]})$fatal(1,"FAIL: DVI wrapper rising lane/order");
   if({tmds_clk_n,tmds_data_n}!==~{tmds_clk_p,tmds_data_p})$fatal(1,"FAIL: DVI differential polarity");
   serial_checks=serial_checks+4;
  end
  cycle=cycle+1;
 end
 always @(negedge pixelclk5x)begin
  #0.3;
  if(checking)begin
   if({tmds_clk_p,tmds_data_p}!=={active[3][bit_index+1],active[2][bit_index+1],active[1][bit_index+1],active[0][bit_index+1]})$fatal(1,"FAIL: DVI wrapper falling lane/order");
   serial_checks=serial_checks+4;
  end
 end
 always @(posedge pixelclk)begin
  #0.01;
  if(!rst_p && pixels>8)begin
   for(j=0;j<3;j=j+1)begin
    case(j)0:word=dut.blue;1:word=dut.green;2:word=dut.red;endcase
    if(de_history[1])begin
     q=word[9]?~word[7:0]:word[7:0];decoded[0]=q[0];
     for(k=1;k<8;k=k+1)decoded[k]=word[8]?(q[k]^q[k-1]):~(q[k]^q[k-1]);
     if(decoded!==rgb_history[1][j*8+:8])$fatal(1,"FAIL: DVI channel decode/mapping");
    end else begin
     if(j==0)case(ctl_history[1])0:control_word=10'b1101010100;1:control_word=10'b0010101011;2:control_word=10'b0101010100;3:control_word=10'b1010101011;endcase
     else control_word=10'b1101010100;
     if(word!==control_word)$fatal(1,"FAIL: DVI blanking/control channel");
    end
    decode_checks=decode_checks+1;
   end
  end
  rgb_history[1]=rgb_history[0];rgb_history[0]={red_din,green_din,blue_din};
  ctl_history[1]=ctl_history[0];ctl_history[0]={vsync,hsync};de_history={de_history[0],de};pixels=pixels+1;
 end
 integer n;
 initial begin
  repeat(12)@(negedge pixelclk);rst_p=0;checking=1;
  for(n=0;n<1024;n=n+1)begin
   @(negedge pixelclk);blue_din=n;green_din=n^8'h5a;red_din=255-n;
   de=n%13!=0;hsync=n[0];vsync=n[1];
  end
  repeat(5)@(negedge pixelclk);checking=0;
  if(decode_checks<3000 || serial_checks<40000)$fatal(1,"FAIL: DVI insufficient checks");
  $display("PASS: dvi_encoder_contract three RGB channels/independent decode/four blue controls/blanking/serialized lane mapping/both edges/clock pair decode=%0d bits=%0d",decode_checks,serial_checks);$finish;
 end
 initial begin #100000;$fatal(1,"FAIL: DVI contract timeout");end
endmodule
