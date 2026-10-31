`timescale 1ns/1ps
module compact_identity_tb;
 reg clk=0,rst=1,sof=0;
 always #1 clk=~clk;
 reg [11:0] x=0,y=0;
 reg [2:0] stage=2;
 wire [23:0] pixel_out;
 wire [31:0] displayed_token;
 candidate_overlay dut(.clk(clk),.rst(rst),.sof(sof),.snapshot_valid(1'b1),
 .candidate_valid(1'b1),.text_codes(128'h85868720202036303234323032323538),
 .text_token(32'd7),.seat(32'd1),.stage(stage),.x(x),.y(y),.de(1'b1),
 .pixel_in(24'h123456),.pixel_out(pixel_out),.displayed_token(displayed_token));
 wire ta;wire [23:0] tp;
 text_overlay status(.x(x),.y(y),.stage_id(4'd2),.risk_level(4'd0),
 .zone_id(4'd0),.event_code(8'h50),.mute(1'b0),.text_active(ta),.text_pixel(tp));
 integer col,row,changed;
 initial begin
   repeat(3) @(negedge clk);rst=0;sof=1;
   @(negedge clk);sof=0;
   x=250;y=100;#1;
   if(pixel_out!=24'h123456) $fatal(1,"unused name background still hides video");
   x=164;y=110;#1;
   if(pixel_out!=24'h123456) $fatal(1,"ID background extends beyond last digit");
   x=130;y=130;#1;
   if(pixel_out!=24'h123456) $fatal(1,"unused seat background still hides video");
   x=110;y=145;#1;
   if(pixel_out!=24'h123456) $fatal(1,"unused confirmation background still hides video");
   changed=0;
   for(row=88;row<152;row=row+1) for(col=16;col<368;col=col+1) begin
     x=col;y=row;#1;if(pixel_out!=24'h123456) changed=changed+1;
   end
   if(changed!=7488 || displayed_token!=7) $fatal(1,"compact area or presentation ack changed");
   x=150;y=40;#1;if(ta) $fatal(1,"unused identity status background hides video");
   x=90;y=45;#1;if(!ta) $fatal(1,"identity status text clipped");
   $display("PASS compact identity background area=7488 prior=22528; glyph positions and ack preserved");
   $finish;
 end
endmodule
