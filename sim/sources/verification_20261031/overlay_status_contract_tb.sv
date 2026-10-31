`timescale 1ns/1ps
module overlay_status_contract_tb;
 reg [23:0] pixel_in=24'h123456;reg [11:0] x=0,y=0;reg de=0;
 reg [11:0] roi_pickup_x0=0,roi_pickup_y0=0,roi_pickup_x1=0,roi_pickup_y1=0;
 reg [11:0] roi_operation_x0=0,roi_operation_y0=0,roi_operation_x1=0,roi_operation_y1=0;
 reg [11:0] roi_forbidden_x0=0,roi_forbidden_y0=0,roi_forbidden_x1=0,roi_forbidden_y1=0;
 reg [3:0] stage_id=0,risk_level=0,zone_id=0;reg [7:0] event_code=0;
 reg mute=0,alarm_active=0,warning_active=0;
 reg [7:0] motion_pickup=0,motion_operation=0,motion_forbidden=0,motion_global=0;
 wire [23:0] pixel_out,disabled_out;
 overlay_status dut(.*);overlay_status #(.ENABLE(0)) disabled(.pixel_out(disabled_out),.*);
 integer i;
 initial begin
  #1;if(pixel_out!==pixel_in)$fatal(1,"FAIL: overlay blanking pass through");
  de=1;#1;if(pixel_out!==24'h404040)$fatal(1,"FAIL: idle strip");
  motion_global=8;#1;if(pixel_out!==24'hffffff)$fatal(1,"FAIL: motion strip");
  alarm_active=1;
  risk_level=0;#1;if(pixel_out!==24'h20a040)$fatal(1,"FAIL: risk green");
  risk_level=1;#1;if(pixel_out!==24'hd0b020)$fatal(1,"FAIL: risk amber");
  risk_level=2;#1;if(pixel_out!==24'hd03030)$fatal(1,"FAIL: risk red priority");
  y=16;x=600;#1;if(pixel_out!==pixel_in)$fatal(1,"FAIL: bar boundary");
  for(i=0;i<256;i=i+1)begin x=600+i;y=100;pixel_in=$random;#1;
   if(pixel_out!==pixel_in || disabled_out!==pixel_in)$fatal(1,"FAIL: normal/disabled video pass through");
  end
  x=8;y=24;#1;if(pixel_out!==24'h101820 && pixel_out!==24'hf8fafc)$fatal(1,"FAIL: text palette");
  de=0;#1;if(pixel_out!==pixel_in)$fatal(1,"FAIL: text blanking");
  $display("PASS: overlay_status_contract DE/disabled passthrough/strip boundary/motion/risk priority/text palette/256 pixels");$finish;
 end
endmodule
