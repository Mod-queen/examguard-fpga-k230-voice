`timescale 1ns/1ps
module operator_alarm_contract_tb;
 reg clk=0,rst=1;always #5 clk=~clk;
 reg [3:0] key=15;reg mute_toggle_pulse=0;
 wire alarm_ack_pulse,buzzer_mute,manual_event_pulse;wire [3:0] key_pressed,key_press_pulse;
 user_control #(.CLK_FREQ_HZ(1000),.DEBOUNCE_MS(2)) controls(.*);
 reg warning_active=0,alarm_active=0,mute=0;wire beep;
 alarm_beep #(.CLOCK_HZ(10000),.TONE_HZ(1000),.WARNING_ON_MS(2),.WARNING_OFF_MS(3)) sound(.*);
 integer acks=0,manuals=0,k,highs=0,changes=0;reg old=0;
 always @(posedge clk)if(!rst)begin if(alarm_ack_pulse)acks=acks+1;if(manual_event_pulse)manuals=manuals+1;end
 task press(input integer bit_index);begin
  @(negedge clk);key[bit_index]=0;repeat(12) @(negedge clk);
  key[bit_index]=1;repeat(12) @(negedge clk);
 end endtask
 initial begin
  repeat(4) @(negedge clk);rst=0;
  press(0);press(2);press(1);
  if(acks!=1 || manuals!=1 || !buzzer_mute)$fatal(1,"FAIL: operator key mapping/one pulse");
  @(negedge clk);mute_toggle_pulse=1;@(negedge clk);mute_toggle_pulse=0;
  if(buzzer_mute)$fatal(1,"FAIL: voice mute toggle");
  // A short active-low glitch does not constitute a stable press.
  @(negedge clk);key[0]=0;@(negedge clk);key[0]=1;repeat(10)@(negedge clk);
  if(acks!=1)$fatal(1,"FAIL: debounce accepted glitch");
  alarm_active=1;repeat(2)@(negedge clk);
  for(k=0;k<40;k=k+1)begin @(negedge clk);highs=highs+beep;if(beep!=old)changes=changes+1;old=beep;end
  if(highs<18 || highs>22 || changes<7)$fatal(1,"FAIL: alarm tone frequency/duty");
  mute=1;#1;if(beep)$fatal(1,"FAIL: immediate mute");
  repeat(8)@(negedge clk);mute=0;alarm_active=0;warning_active=1;
  repeat(25)@(negedge clk);
  for(k=0;k<20;k=k+1)begin @(negedge clk);if(beep)$fatal(1,"FAIL: warning silent gap");end
  warning_active=0;repeat(3)@(negedge clk);if(beep)$fatal(1,"FAIL: normal silence");
  rst=1;repeat(2)@(negedge clk);if(beep || buzzer_mute)$fatal(1,"FAIL: operator reset");
  $display("PASS: operator_alarm_contract debounce/key mapping/voice mute/continuous tone/duty/warning gap/reset");$finish;
 end
 initial begin #100000;$fatal(1,"FAIL: operator alarm timeout");end
endmodule
