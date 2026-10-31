`timescale 1ns/1ps

module config_parser_contract_tb;
 reg clk=0,rst=1,valid=0;reg [7:0] data=0;always #5 clk=~clk;
 wire cfg_we;wire [1:0] cfg_region;wire [11:0] cfg_x0,cfg_y0,cfg_x1,cfg_y1;
 wire [7:0] cfg_thr,cfg_version;wire [2:0] cfg_status;
 config_rx dut(.*);
 integer replies=0;reg [2:0] status;reg [7:0] version;
 always @(posedge clk) begin #1;if(!rst && cfg_we)begin replies=replies+1;status=cfg_status;version=cfg_version;end end
 task send(input string s);integer k;begin
  for(k=0;k<s.len();k=k+1)begin @(negedge clk);valid=1;data=s[k];@(negedge clk);valid=0;end
  repeat(4) @(negedge clk);
 end endtask
 task check(input integer n,input [2:0] code,input [7:0] v);begin
  if(replies!=n || status!==code || version!==v)$fatal(1,"FAIL: configuration reply n=%0d code=%0d version=%0d",replies,status,version);
 end endtask
 initial begin
  repeat(4) @(negedge clk);rst=0;
  send("RC,1,100,50,300,200,12\n");check(1,0,1);
  if({cfg_region,cfg_x0,cfg_y0,cfg_x1,cfg_y1,cfg_thr}!={2'd1,12'd100,12'd50,12'd300,12'd200,8'd12})$fatal(1,"FAIL: parsed payload");
  send($sformatf("RC,3,0,0,1280,720,255%c%c",8'd13,8'd10));check(2,0,2);
  send("RC,4,0,0,100,100,10\n");check(3,1,2);
  send("RC,2,500,100,500,200,10\n");check(4,2,2);
  send("RC,2,0,0,100,800,10\n");check(5,3,2);
  send("RC,2,0,0,100,100,300\n");check(6,4,2);
  send("RC,1,10,20,30\n");check(7,5,2);
  send("ST,1,2,3,4,5,6\n");check(7,5,2);
  send("RC,2,640,360,1279,719,20\n");check(8,0,3);
  @(negedge clk);rst=1;repeat(2) @(negedge clk);rst=0;
  send("RC,1,0,0,1,1,0\n");if(cfg_version!=1)$fatal(1,"FAIL: parser reset version");
  $display("PASS: config_parser_contract valid ROI/full boundaries/CRLF/invalid region-X-Y-threshold/malformed/foreign/recovery/reset");$finish;
 end
 initial begin #100000;$fatal(1,"FAIL: config timeout");end
endmodule
