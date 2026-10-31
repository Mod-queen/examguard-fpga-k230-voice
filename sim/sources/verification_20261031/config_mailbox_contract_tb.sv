`timescale 1ns/1ps
module config_mailbox_contract_tb;
reg src_clk=0,dst_clk=0,src_rst=1,dst_rst=1,src_valid=0;always #7 src_clk=~src_clk;always #5 dst_clk=~dst_clk;wire dst_valid;
reg [7:0] src_version=0;wire [7:0] dst_version;
reg [1:0] src_region=0;wire [1:0] dst_region;
reg [11:0] src_x0=0;wire [11:0] dst_x0;
reg [11:0] src_y0=0;wire [11:0] dst_y0;
reg [11:0] src_x1=0;wire [11:0] dst_x1;
reg [11:0] src_y1=0;wire [11:0] dst_y1;
reg [7:0] src_thr=0;wire [7:0] dst_thr;
config_mailbox dut(.*);integer k,received=0;always @(posedge dst_clk) begin #1;if(!dst_rst && dst_valid)begin if({dst_version,dst_region,dst_x0,dst_y0,dst_x1,dst_y1,dst_thr}!=={src_version,src_region,src_x0,src_y0,src_x1,src_y1,src_thr})$fatal(1,"FAIL: mailbox torn payload");received=received+1;end end
initial begin repeat(6) @(negedge src_clk);src_rst=0;dst_rst=0;for(k=0;k<100;k=k+1)begin @(negedge src_clk);
src_version=$random;
src_region=$random;
src_x0=$random;
src_y0=$random;
src_x1=$random;
src_y1=$random;
src_thr=$random;
src_valid=1;@(negedge src_clk);src_valid=0;repeat(10) @(negedge dst_clk);if(received!=k+1)$fatal(1,"FAIL: mailbox duplicate/lost sample");end
src_rst=1;dst_rst=1;repeat(5) @(negedge src_clk);if({dst_version,dst_region,dst_x0,dst_y0,dst_x1,dst_y1,dst_thr}!==0 || dst_valid)$fatal(1,"FAIL: mailbox reset");$display("PASS: config_mailbox 100 coherent snapshots/unrelated clocks/no duplicates/reset (source hold contract)");$finish;end
initial begin #100000;$fatal(1,"FAIL: mailbox timeout");end
endmodule
