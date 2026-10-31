`timescale 1ns/1ps
// Quantization-compatible upper-bound replay, not original 24-bit source pixels.
module camera_black_noise_tb;
  reg clk=0; always #1 clk=~clk;
  reg rst=1,sof=0,de=0;
  reg [11:0] x=0,y=0;
  reg [23:0] pixel=0;
  reg [23:0] pixels[0:57599];
  wire old_covered,new_covered,old_black,new_black,old_valid,new_valid;
  camera_black_gate #(.WIDTH(320),.HEIGHT(180),.BLACK_MAX(16),.CONFIRM_FRAMES(2)) old_gate
    (.clk(clk),.rst(rst),.sof(sof),.de(de),.x(x),.y(y),.pixel(pixel),
     .covered(old_covered),.frame_is_black(old_black),.frame_valid(old_valid));
  camera_black_gate #(.WIDTH(320),.HEIGHT(180),.BLACK_MAX(31),.CONFIRM_FRAMES(2),.RELEASE_FRAMES(1)) new_gate
    (.clk(clk),.rst(rst),.sof(sof),.de(de),.x(x),.y(y),.pixel(pixel),
     .covered(new_covered),.frame_is_black(new_black),.frame_valid(new_valid));
  task frame;
    input integer kind;
    integer i;
    begin
      for(i=0;i<57600;i=i+1) begin
        @(negedge clk);sof=0;de=1;
        if(kind==0) pixel=pixels[i];
        else if(kind==1) pixel=(i<56448)?24'h1f1f1f:24'hffffff;
        else if(kind==2) pixel=(i<56447)?24'h1f1f1f:24'hffffff;
        else pixel=24'h202020;
      end
      @(negedge clk);de=0;
      @(negedge clk);sof=1;
      @(negedge clk);sof=0;
    end
  endtask
  initial begin
    $readmemh("field_noise_upper.hex",pixels);
    repeat(4) @(negedge clk);rst=0;sof=1;
    @(negedge clk);sof=0;
    frame(0);frame(0);
    if(!old_valid || old_black || old_covered) $fatal(1,"old threshold must reject the quantization-compatible dark noise scenario");
    if(!new_valid || !new_black || !new_covered) $fatal(1,"near-black31 candidate must accept measured noise envelope");
    frame(2);
    if(!new_valid || new_black || new_covered) $fatal(1,"less than98 percent must remain rejected");
    frame(1);frame(1);
    if(!new_black || !new_covered) $fatal(1,"exact98 percent31 must pass");
    frame(3);
    if(new_black || new_covered) $fatal(1,"channel32 must remain outside near-black");
    $display("PASS quantization-compatible measured dark-noise replay, exact98 boundary,31/32 separation");
    $finish;
  end
  initial begin #2000000;$fatal(1,"timeout");end
endmodule
