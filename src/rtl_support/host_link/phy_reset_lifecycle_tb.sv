`timescale 1ns/1ps
// Real PHY config + real MDIO bit-shifter. A separate wire-level slave checks
// full BMCR frames and rising-edge16bit readback, with slave bits launched
// after falling MDC. No RGMII/real PHY delay-mode claims.
module phy_reset_lifecycle_tb;
    reg clk=0,clock_running=1,rst_n=0;
    always #10 if(clock_running) clk=~clk;
    wire phy_rst_n,phy_init_done,mdc,link_up;
    wire [1:0] link_speed;
    wire [15:0] rddata;
    tri mdio;
    pullup pull(mdio);
    phy_reg_config #(.SYS_CLOCK(50000000),.MDC_CLOCK(1000000),.RST_HOLD(20),.GO_CNT(60),.CNT_MAX(4000),.SETTLE_MAX(20000)) dut(.*);
    reg cap_clock=0,ui_clock=0,eth_clock=0;
    always #7 cap_clock=~cap_clock;
    always #5 ui_clock=~ui_clock;
    always #4 eth_clock=~eth_clock;
    wire [3:0] transport_resets;
    evidence_reset_barrier barrier(.arst(!rst_n || !phy_init_done),.clocks({eth_clock,ui_clock,cap_clock,clk}),.resets(transport_resets));
    reg slave_drive=0,slave_bit=1;
    reg respond=1;
    assign mdio=slave_drive ? slave_bit : 1'bz;
    // Deliberately select two different PHY statuses and verify common reset
    // drops the sticky link qualification rather than reusing the prior epoch.
    reg [15:0] bmsr=16'h0024,stat1000=16'h0800;
    reg [63:0] shift=0;
    integer preamble=0,index=0,writes=0,reads=0,phase=0;
    reg framing=0;
    reg [1:0] op;
    reg [4:0] address;
    integer falling_edges=0;
    time last_rise=0;
    always @(posedge mdc) begin
        if(rst_n && !dut.control_rst) begin
            if(last_rise && $time-last_rise!=480) $fatal(1,"FAIL: PHY divider changed period=%0t",$time-last_rise);
            last_rise=$time;
        end
        if(!rst_n || !phy_rst_n) begin preamble=0;framing=0;index=0;end
        else if(!framing) begin
            if(mdio===1'b1) preamble=preamble+1;
            else if(mdio===1'b0 && preamble>=32) begin framing=1;index=1;shift=0;preamble=0;end
            else preamble=0;
        end else begin
            shift={shift[62:0],mdio};
            if(index==3) op=shift[1:0];
            if(index==13) begin
                address=shift[4:0];
                if(shift[9:5]!=0) $fatal(1,"FAIL: wrong PHY address");
            end
            if(index==31) begin
                if(op==1) begin
                    if(address!=0 || shift[15:0]!==16'h1340) $fatal(1,"FAIL: PHY BMCR wire frame %h",shift);
                    writes=writes+1;
                end else if(op==2) reads=reads+1;
                else $fatal(1,"FAIL: PHY management operation");
                framing=0;index=0;
            end else index=index+1;
        end
    end
    always @(negedge rst_n) begin last_rise=0;end
    // Slave updates only after falling MDC, holds across rising sample edge.
    // Index is the NEXT bit to be sampled by the wire-level frame decoder.
    always @(negedge mdc or negedge rst_n) begin
        #1;
        slave_drive=0;slave_bit=1;
        if(rst_n && respond && framing && op==2) begin
            if(index==15) begin slave_drive=1;slave_bit=0;end
            if(index>=16 && index<=31) begin
                slave_drive=1;
                slave_bit=address==1 ? bmsr[31-index] : stat1000[31-index];
            end
        end
    end
    always @(posedge dut.done) begin
        #1;
        if(respond && dut.if_read_r && rddata!==(dut.reg_addr_r==1 ? bmsr : stat1000))
            $fatal(1,"FAIL: MDIO16bit readback addr=%d got=%h expected=%h",dut.reg_addr_r,rddata,dut.reg_addr_r==1 ? bmsr : stat1000);
    end
    always @(negedge mdc) begin
        #1;
        if(dut.mdio_rst) begin
            if(dut.start!==0 || dut.link_rdy!==0 || dut.mdio_bit_shift.done!==0 || dut.mdio_bit_shift.mdio_oe!==0)
                $fatal(1,"FAIL: PHY engines not reset together");
        end
    end
    task assert_reset;
        begin
            #3;rst_n=0;#1;
            if(phy_rst_n!==0 || !dut.mdio_rst || dut.start!==0 || dut.link_rdy!==0 || transport_resets!==4'hf)
                $fatal(1,"FAIL: PHY async reset assertion");
            #2;rst_n=1;
        end
    endtask
    task wait_gigabit;
        integer n;
        begin
            n=0;
            while((!link_up || link_speed!=2 || !phy_init_done) && n<10000) begin @(negedge clk);n=n+1;end
            if(n==10000 || dut.settle_done) $fatal(1,"FAIL: PHY gigabit readback before fallback");
            wait(transport_resets==0);
        end
    endtask
    integer start_writes,start_reads;
    initial begin
        #100;rst_n=1;
        wait(dut.management_go);#1;
        for(phase=1;phase<=3;phase=phase+1) begin
            @(negedge mdc);#2;
            if(dut.mdio_rst!==(phase<3)) $fatal(1,"FAIL: MDIO release stage=%0d",phase);
            if(dut.start) $fatal(1,"FAIL: MDIO started on release edge");
        end
        wait_gigabit();if(writes!=1) $fatal(1,"FAIL: first epoch BMCR count");
        start_writes=writes;
        // Exercise BOTH extremes of the16bit word, not only link status bits.
        bmsr=16'ha525;stat1000=16'h8801;
        // Reset active serial transaction, guarantee a fresh complete BMCR.
        wait(dut.mdio_bit_shift.state==8'h08);assert_reset();
        wait_gigabit();if(writes!=start_writes+1) $fatal(1,"FAIL: old PHY frame replay/second BMCR");
        // No master clock at all: short reset still asserts both engines, PHY
        // pin remains low until clock and threshold qualification return.
        @(negedge clk);clock_running=0;assert_reset();#157;
        if(phy_rst_n || phy_init_done || !dut.mdio_rst || dut.start || transport_resets!==4'hf) $fatal(1,"FAIL: PHY stopped-control reset");
        clock_running=1;wait_gigabit();
        // Valid replies without link must not latch gigabit. A later real
        // gigabit status in the same epoch may qualify without another BMCR.
        bmsr=16'h8001;stat1000=16'h0000;assert_reset();
        start_reads=reads;wait(reads>=start_reads+2);repeat(100) @(negedge clk);
        if(link_up || dut.link_rdy) $fatal(1,"FAIL: PHY no-link response qualified");
        bmsr=16'h0024;stat1000=16'h0800;wait_gigabit();
        // Absent PHY replies must retain old fallback policy without claiming
        // link_up/gigabit. Fresh reset clears prior sticky qualification.
        respond=0;assert_reset();wait(dut.settle_done);repeat(5) @(negedge clk);
        if(!phy_init_done || link_up || link_speed==2 || dut.link_rdy) $fatal(1,"FAIL: PHY fallback/reset qualification init=%b up=%b speed=%b sticky=%b",phy_init_done,link_up,link_speed,dut.link_rdy);
        // Repeated sub-clock pulses during startup restart release stages.
        assert_reset();@(posedge clk);#1;assert_reset();
        if(phy_rst_n || !dut.mdio_rst) $fatal(1,"FAIL: PHY retrigger reset");
        $display("PASS: phy_reset_lifecycle control3/MDC3 release/BMCR wire/readback/reset-active/stopclock/shortpulse/fallback");$finish;
    end
    initial begin #5000000;$fatal(1,"FAIL: PHY lifecycle timeout writes=%0d reads=%0d link=%b speed=%b",writes,reads,link_up,link_speed);end
endmodule
