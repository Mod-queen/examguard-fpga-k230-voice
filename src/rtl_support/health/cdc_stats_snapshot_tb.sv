`timescale 1ns/1ps
module cdc_stats_snapshot_tb;
    reg arst=1,src_clk=0,dst_clk=0,run_src=1;
    always #5 if(run_src) src_clk=~src_clk;
    always #10 dst_clk=~dst_clk;
    wire [1:0] resets;
    wire src_rst=resets[0],dst_rst=resets[1];
    evidence_reset_barrier #(.DOMAINS(2)) barrier(.arst(arst),.clocks({dst_clk,src_clk}),.resets(resets));
    reg [31:0] seqnum=0;
    wire [255:0] src_stats={seqnum,~seqnum,seqnum^32'h55aa55aa,seqnum+32'd1,seqnum,~seqnum,seqnum,~seqnum};
    wire [255:0] stats;
    wire valid;
    wire [31:0] age_cycles;
    cdc_stats_snapshot dut(.*);
    always @(posedge src_clk) if(src_rst) seqnum<=0;else seqnum<=seqnum+1;
    integer samples=0;
    reg [31:0] previous=0;
    reg [255:0] held;
    always @(posedge dst_clk) if(!dst_rst && valid) begin
        if(stats!=={stats[255:224],~stats[255:224],stats[255:224]^32'h55aa55aa,stats[255:224]+32'd1,
            stats[255:224],~stats[255:224],stats[255:224],~stats[255:224]}) $fatal(1,"FAIL: torn statistics snapshot");
        if(stats[255:224]<previous) $fatal(1,"FAIL: statistics order regressed");
        previous=stats[255:224];samples=samples+1;
    end
    initial begin
        #80;arst=0;wait(resets==0);wait(samples>100);
        @(negedge src_clk);run_src=0;repeat(30) @(negedge dst_clk);held=stats;
        repeat(50) @(negedge dst_clk);
        if(!valid || age_cycles<50 || stats!==held) $fatal(1,"FAIL: stopped stats clock fabricated progress");
        #1;arst=1;#3;arst=0;repeat(20) @(negedge dst_clk);
        if(!dst_rst || valid) $fatal(1,"FAIL: old stats leaked while source stopped/reset");
        previous=0;run_src=1;wait(resets==0);wait(valid);repeat(20) @(negedge dst_clk);
        $display("PASS: cdc_stats_snapshot atomic 256bit changing counters/stopped-clock age/common-reset epoch");$finish;
    end
    initial begin #1000000;$fatal(1,"FAIL: stats snapshot timeout");end
endmodule
