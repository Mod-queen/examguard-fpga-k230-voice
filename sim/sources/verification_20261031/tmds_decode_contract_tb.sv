`timescale 1ns/1ps

module tmds_decode_contract_tb;
 reg clk=0,rst_p=1,de=0,c0=0,c1=0;reg [7:0] din=0;wire [9:0] dout;
 always #5 clk=~clk;encode dut(.*);
 reg [7:0] bytes[0:1];reg [1:0] controls[0:1];reg [1:0] active=0;
 reg [7:0] q,decoded;reg [9:0] ctl;integer i,n=0,checks=0;
 always @(posedge clk)begin
  #0.01;
  if(!rst_p && n>=4)begin
   if(active[1])begin
    q=dout[9]?~dout[7:0]:dout[7:0];decoded[0]=q[0];
    for(i=1;i<8;i=i+1)decoded[i]=dout[8]?(q[i]^q[i-1]):~(q[i]^q[i-1]);
    if(decoded!==bytes[1])$fatal(1,"FAIL: TMDS independent decode expected=%h actual=%h word=%b",bytes[1],decoded,dout);
   end else begin
    case(controls[1])0:ctl=10'b1101010100;1:ctl=10'b0010101011;2:ctl=10'b0101010100;3:ctl=10'b1010101011;endcase
    if(dout!==ctl)$fatal(1,"FAIL: TMDS control code");
   end
   checks=checks+1;
  end
  bytes[1]=bytes[0];bytes[0]=din;controls[1]=controls[0];controls[0]={c1,c0};active={active[0],de};n=n+1;
 end
 integer k;
 initial begin
  repeat(4) @(negedge clk);rst_p=0;
  for(k=0;k<1024;k=k+1)begin @(negedge clk);din=k;de=(k%17!=0);c0=k[0];c1=k[1];end
  repeat(4) @(negedge clk);
  if(checks<1024)$fatal(1,"FAIL: TMDS coverage count");
  $display("PASS: tmds_decode_contract all256 byte values/repeated disparity histories/independent decoder/four control codes/pipeline checks=%0d",checks);$finish;
 end
 initial begin #20000;$fatal(1,"FAIL: TMDS timeout");end
endmodule
