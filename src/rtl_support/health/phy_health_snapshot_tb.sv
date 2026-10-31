`timescale 1ns/1ps
module phy_health_snapshot_tb;
    reg clk=0,mdc=0,run_mdc=1,arst=1;
    always #10 clk=~clk;
    always #113 if(run_mdc) mdc=~mdc;
    reg status_valid=0,link_up=0,full_duplex=0;
    reg [1:0] link_speed=0;
    reg [31:0] phy_id=0;
    reg [15:0] tx_delay_raw=0,rx_delay_raw=0;
    wire [31:0] summary;
    phy_health_snapshot #(.STALE_CYCLES(100)) dut(.*);
    integer i;
    reg [7:0] previous=0;
    task automatic set_sample(input [7:0] sample);
        begin
            @(posedge mdc);phy_id=sample[7]?32'h001cc916:0;status_valid=sample[6];
            rx_delay_raw=sample[5]?8:0;tx_delay_raw=sample[4]?256:0;
            full_duplex=sample[3];link_up=sample[2];link_speed=sample[1:0];
        end
    endtask
    initial begin
        repeat(5) @(negedge clk);arst=0;
        set_sample(8'hfe);wait(summary==32'h010002fe);
        for(i=0;i<20;i=i+1) begin
            previous=summary[7:0];
            set_sample(i[0]?8'hfe:8'h01);
            repeat(70) begin
                @(negedge clk);
                if(summary[7:0]!=previous && summary[7:0]!=(i[0]?8'hfe:8'h01)) $fatal(1,"FAIL: torn PHY summary");
            end
        end
        @(posedge mdc);run_mdc=0;repeat(200) @(negedge clk);
        if(!summary[9] || !summary[8]) $fatal(1,"FAIL: stopped MDC not stale");
        #3;arst=1;#3;arst=0;repeat(10) @(negedge clk);
        if(summary!==32'h01000000) $fatal(1,"FAIL: reset retained old PHY summary");
        run_mdc=1;set_sample(8'hdc);wait(summary==32'h010002dc);
        $display("PASS: phy_health_snapshot coherent/unknown/stale/stopped-clock-reset/recovery");$finish;
    end
    initial begin #200000;$fatal(1,"FAIL: PHY snapshot timeout");end
endmodule
