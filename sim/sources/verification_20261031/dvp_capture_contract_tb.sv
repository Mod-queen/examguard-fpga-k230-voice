`timescale 1ns/1ps

module dvp_capture_contract_tb;
 reg PCLK=0,Rst_p=1,Vsync=0,Href=0;reg [7:0] Data=0;
 always #5 PCLK=~PCLK;
 wire ImageState,DataValid,DataHs,DataVs;wire [15:0] DataPixel;wire [11:0] Xaddr,Yaddr;
 DVP_Capture dut(.*);
 integer received=0,expected_count=0,frame,line,pixel,i;reg [15:0] expected[0:63];reg watching=0;
 always @(posedge PCLK) begin #1;
  if(!Rst_p && DataValid) begin
   if(!watching || received>=expected_count || DataPixel!==expected[received]) $fatal(1,"FAIL: DVP byte assembly/order %0d got %h",received,DataPixel);
   if(Xaddr!==(received%4+1) || Yaddr!==(received/4+1)) $fatal(1,"FAIL: DVP pixel coordinates %0d/%0d",Xaddr,Yaddr);
   received=received+1;
  end
 end
 task sync_frame;begin
  @(negedge PCLK);Vsync=1;Href=0;repeat(4) @(negedge PCLK);
  Vsync=0;repeat(4) @(negedge PCLK);
 end endtask
 task send_line(input integer l,input integer admitted);reg [15:0] value;begin
  for(pixel=0;pixel<4;pixel=pixel+1) begin
   value=16'h8100+l*16+pixel;
   if(admitted) begin expected[expected_count]=value;expected_count=expected_count+1;end
   @(negedge PCLK);Href=1;Data=value[15:8];
   @(negedge PCLK);Data=value[7:0];
  end
  @(negedge PCLK);Href=0;repeat(5) @(negedge PCLK);
 end endtask
 initial begin
  repeat(4) @(negedge PCLK);Rst_p=0;
  for(frame=0;frame<9;frame=frame+1) begin sync_frame();send_line(0,0);end
  if(received) $fatal(1,"FAIL: startup frames exposed");
  sync_frame();watching=1;
  for(line=0;line<3;line=line+1)send_line(line,1);
  if(received!=12 || ImageState) $fatal(1,"FAIL: DVP final count/state");
  @(negedge PCLK);Href=1;Data=8'hff;
  @(negedge PCLK);Rst_p=1;Href=0;#1;
  if(DataValid || !ImageState) $fatal(1,"FAIL: DVP reset cancellation");
  repeat(4) @(negedge PCLK);Rst_p=0;repeat(8) @(negedge PCLK);
  if(DataValid) $fatal(1,"FAIL: stale pixel after reset");
  $display("PASS: dvp_capture_contract nine startup frames discarded/RGB565 byte order/12 pixels/three lines/coordinates/mid-pixel reset");$finish;
 end
 initial begin #50000;$fatal(1,"FAIL: DVP timeout");end
endmodule
