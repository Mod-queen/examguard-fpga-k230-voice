`timescale 1ns/1ps
// Real 720p driver -> real enhancement -> cover gate. No idealized coordinates.
module camera_black_driver_tb;
  reg clk=0, reset=1;
  always #1 clk=~clk;
  wire [11:0] x,y,ex,ey;
  wire de,sof,ed,es;
  wire [7:0] r,g,b,er,eg,eb;
  wire covered,valid,black;
  disp_driver driver(.ClkDisp(clk),.Rst_n(!reset),.Data(24'h000000),
    .H_Addr(x),.V_Addr(y),.Disp_Sof(sof),.Disp_DE(de),
    .Disp_Red(r),.Disp_Green(g),.Disp_Blue(b));
  color_enhance enhance(.clk(clk),.rst(reset),.pixel_r(r),.pixel_g(g),.pixel_b(b),
    .x(x),.y(y),.de(de),.sof(sof),.enh_r(er),.enh_g(eg),.enh_b(eb),
    .enh_x(ex),.enh_y(ey),.enh_de(ed),.enh_sof(es));
  camera_black_gate #(.CONFIRM_FRAMES(2)) gate(.clk(clk),.rst(reset),
    .sof(es),.de(ed),.x(ex),.y(ey),.pixel({er,eg,eb}),
    .covered(covered),.frame_valid(valid),.frame_is_black(black));
  integer total=0,inrange=0,n=0,minx=4095,maxx=0,miny=4095,maxy=0;
  always @(posedge clk) if(!reset) begin
    if(es) begin
      if(n>0) $display("DRIVER frame=%0d de_pixels=%0d in_range=%0d x=%0d..%0d y=%0d..%0d gate_count=%0d",n,total,inrange,minx,maxx,miny,maxy,gate.count);
      total=0;inrange=0;minx=4095;maxx=0;miny=4095;maxy=0;n=n+1;
      if(n==4) begin
        #0.1;
        if(!valid || !black || !covered) $fatal(1,"REPRO: real driver pure black never confirms cover");
        $display("PASS real driver pure-black cover confirmed with all 921600 active pixels");
        $finish;
      end
    end
    if(ed) begin
      total=total+1;
      if(ex<1280 && ey<720) inrange=inrange+1;
      if(ex<minx) minx=ex;if(ex>maxx) maxx=ex;
      if(ey<miny) miny=ey;if(ey>maxy) maxy=ey;
    end
  end
  initial begin repeat(10) @(negedge clk);reset=0;end
  initial begin #15000000;$fatal(1,"real driver timeout");end
endmodule
