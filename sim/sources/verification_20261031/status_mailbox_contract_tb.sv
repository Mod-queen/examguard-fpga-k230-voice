`timescale 1ns/1ps
module status_mailbox_contract_tb;
reg src_clk=0,dst_clk=0,src_rst=1,dst_rst=1,src_valid=0;always #7 src_clk=~src_clk;always #5 dst_clk=~dst_clk;wire dst_valid;
reg [31:0] src_frame_id=0;wire [31:0] dst_frame_id;
reg [3:0] src_stage_id=0;wire [3:0] dst_stage_id;
reg [3:0] src_risk_level=0;wire [3:0] dst_risk_level;
reg [3:0] src_zone_id=0;wire [3:0] dst_zone_id;
reg [31:0] src_timestamp=0;wire [31:0] dst_timestamp;
reg [7:0] src_event_code=0;wire [7:0] dst_event_code;
reg [7:0] src_event_seq=0;wire [7:0] dst_event_seq;
reg [7:0] src_motion_pickup=0;wire [7:0] dst_motion_pickup;
reg [7:0] src_motion_operation=0;wire [7:0] dst_motion_operation;
reg [7:0] src_motion_forbidden=0;wire [7:0] dst_motion_forbidden;
status_mailbox dut(.*);integer k,received=0;always @(posedge dst_clk) begin #1;if(!dst_rst && dst_valid)begin if({dst_frame_id,dst_stage_id,dst_risk_level,dst_zone_id,dst_timestamp,dst_event_code,dst_event_seq,dst_motion_pickup,dst_motion_operation,dst_motion_forbidden}!=={src_frame_id,src_stage_id,src_risk_level,src_zone_id,src_timestamp,src_event_code,src_event_seq,src_motion_pickup,src_motion_operation,src_motion_forbidden})$fatal(1,"FAIL: mailbox torn payload");received=received+1;end end
initial begin repeat(6) @(negedge src_clk);src_rst=0;dst_rst=0;for(k=0;k<100;k=k+1)begin @(negedge src_clk);
src_frame_id=$random;
src_stage_id=$random;
src_risk_level=$random;
src_zone_id=$random;
src_timestamp=$random;
src_event_code=$random;
src_event_seq=$random;
src_motion_pickup=$random;
src_motion_operation=$random;
src_motion_forbidden=$random;
src_valid=1;@(negedge src_clk);src_valid=0;repeat(10) @(negedge dst_clk);if(received!=k+1)$fatal(1,"FAIL: mailbox duplicate/lost sample");end
src_rst=1;dst_rst=1;repeat(5) @(negedge src_clk);if({dst_frame_id,dst_stage_id,dst_risk_level,dst_zone_id,dst_timestamp,dst_event_code,dst_event_seq,dst_motion_pickup,dst_motion_operation,dst_motion_forbidden}!==0 || dst_valid)$fatal(1,"FAIL: mailbox reset");$display("PASS: status_mailbox 100 coherent snapshots/unrelated clocks/no duplicates/reset (source hold contract)");$finish;end
initial begin #100000;$fatal(1,"FAIL: mailbox timeout");end
endmodule
