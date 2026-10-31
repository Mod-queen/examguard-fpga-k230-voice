`timescale 1ns/1ps
module evidence_health_telemetry_tb;
    reg [31:0] phy_summary=32'h010002fe;
    reg clk=0,cap_clk=0,ui_clk=0,eth_clk=0,system_rst=1,arst=1,run_cap=1;
    always #10 clk=~clk;
    always #7 if(run_cap) cap_clk=~cap_clk;
    always #5 ui_clk=~ui_clk;
    always #4 eth_clk=~eth_clk;
    wire [3:0] resets;
    wire control_rst=resets[0],cap_rst=resets[1],ui_rst=resets[2],eth_rst=resets[3];
    evidence_reset_barrier barrier(.arst(arst),.clocks({eth_clk,ui_clk,cap_clk,clk}),.resets(resets));
    reg [31:0] device_id=1,boot_id=2,session_id=3;
    reg [63:0] time_ms=64'h12345678ffffffff;
    reg boot_exhausted=0,id_exhausted=0;
    wire request_enable=!control_rst && !boot_exhausted;
    reg [3:0] fsm_requests=0,source_occupancy=0,source_high_water=0;
    reg [31:0] source_accepted=0,source_rejected=0,source_delivered=0;
    reg [255:0] cap_stats=0,ui_stats=0;
    reg [127:0] eth_stats=0;
    wire [1023:0] report_data;
    wire [23:0] flags;
    wire [31:0] cancel_epochs,blocked_requests;
    evidence_health_telemetry #(.STALE_CYCLES(30)) dut(.*);
    wire [1023:0] report_v2;
    evidence_health_telemetry #(.STALE_CYCLES(30),.ENABLE_PHY_HEALTH(1)) v2(
        .report_data(report_v2),.flags(),.cancel_epochs(),.blocked_requests(),.*);
    always @(negedge clk) begin
        #1;
        if(!system_rst) begin
        if(report_v2[1023:1016]!==8'd2 || report_v2[31:0]!==phy_summary || report_v2[1015:32]!==report_data[1015:32])
            $fatal(1,"FAIL: v2 PHY word displaced old telemetry/hidden by reset");
        end
    end
    initial begin
        repeat(4) @(negedge clk);system_rst=0;arst=0;
        wait(flags[6:4]==7);repeat(3) @(negedge clk);
        if(flags || cancel_epochs) begin
            if(flags!=24'h70 || cancel_epochs) $fatal(1,"FAIL: startup flags/cancel counted startup");
        end
        cap_stats={32'd10,32'd9,32'd8,32'd7,32'd6,32'd5,32'd4,32'd3};
        ui_stats={32'hc0000000,32'd2,32'd1,32'd20,32'd3,32'd4,32'd5,32'd6};
        eth_stats={32'd3,32'd30,32'd2,32'd0};source_accepted=8;source_rejected=4;source_occupancy=8;source_high_water=8;
        wait(report_data[639:384]==cap_stats && report_data[383:128]==ui_stats && report_data[127:0]==eth_stats);
        if(flags[15:10]!=6'b111111 || !flags[3] || report_data[895:864]!=8 || report_data[863:832]!=4)
            $fatal(1,"FAIL: health flags/counter positions");
        @(negedge cap_clk);run_cap=0;wait(flags[7]);
        if(flags[4] || report_data[639:384]!=0) $fatal(1,"FAIL: stale data falsely fresh");
        // Cancel while a source clock is stopped. Reports must invalidate all
        // cached domain values immediately and remain unknown until fresh.
        #1;arst=1;repeat(2) @(negedge clk);fsm_requests=15;
        repeat(3) @(negedge clk);fsm_requests=0;arst=0;repeat(20) @(negedge clk);
        if(flags[6:4] || !flags[0] || cancel_epochs!=1 || blocked_requests!=12 || report_data[639:0]!=0)
            $fatal(1,"FAIL: cancellation epoch invalidation/count blocked=%0d cancel=%0d",blocked_requests,cancel_epochs);
        cap_stats=0;ui_stats=0;eth_stats=0;source_occupancy=0;run_cap=1;boot_id=3;wait(flags[6:4]==7);
        boot_exhausted=1;id_exhausted=1;repeat(2) @(negedge clk);
        if(flags[2:1]!=3 || report_data[959:928]!=3 || cancel_epochs!=1) $fatal(1,"FAIL: boot exhaustion telemetry");
        @(negedge clk);dut.cancel_epochs=32'hffffffff;dut.blocked_requests=32'hffffffff;fsm_requests=15;
        v2.cancel_epochs=32'hffffffff;v2.blocked_requests=32'hffffffff;
        arst=1;repeat(3) @(negedge clk);
        if(cancel_epochs!=32'hffffffff || blocked_requests!=32'hffffffff) $fatal(1,"FAIL: health counters wrapped");
        $display("PASS: evidence_health_telemetry atomic counters/flags/stale source/epoch invalidation/blocked+cancel saturation");$finish;
    end
    initial begin #1000000;$fatal(1,"FAIL: health telemetry timeout flags=%h",flags);end
endmodule
