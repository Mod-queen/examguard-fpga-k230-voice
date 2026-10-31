`timescale 1ns/1ps
module phy_qualification_tb;
    reg clk=0,clock_running=1,rst_n=0;
    always #10 if(clock_running) clk=~clk;
    wire phy_rst_n,phy_init_done,tx_qualified,mdc,link_up,status_valid,full_duplex;
    wire [1:0] link_speed;
    wire [15:0] rddata,tx_delay_raw,rx_delay_raw,physr_raw,speed_raw;
    wire [31:0] phy_id;
    tri1 mdio;
    phy_reg_config #(.MDC_CLOCK(1000000),.RST_HOLD(20),.GO_CNT(60),.CNT_MAX(4000),.SETTLE_MAX(200000)) dut(.*);
    reg respond=1,ignore_page_write=0,fail_read=0;
    reg [31:0] id_value=32'h001cc916;
    reg [15:0] bmsr_value=16'h0024,physr_value=16'h002c,speed_value=16'h0020;
    reg [15:0] tx_value=16'ha581,rx_value=16'h009d,fail_page=0;
    reg [4:0] fail_address=0;
    wire [15:0] page;
    wire [31:0] bmcr_writes,reads,page_checks;
    wire framing;
    wire [5:0] index;
    rtl8211f_wire_model slave(.rst_n(phy_rst_n),.*);
    reg cap_clock=0,ui_clock=0,eth_clock=0;
    always #7 cap_clock=~cap_clock;
    always #5 ui_clock=~ui_clock;
    always #4 eth_clock=~eth_clock;
    wire [3:0] transport_resets;
    evidence_reset_barrier barrier(.arst(!rst_n || !tx_qualified),.clocks({eth_clock,ui_clock,cap_clock,clk}),.resets(transport_resets));
    time last_rise=0;
    always @(negedge rst_n) last_rise=0;
    always @(posedge mdc) if(rst_n && !dut.control_rst) begin
        if(last_rise && $time-last_rise!=480) $fatal(1,"FAIL: divider period changed");
        last_rise=$time;
    end
    task automatic reset_phy;
        begin
            #3;rst_n=0;#2;
            if(phy_rst_n || tx_qualified || transport_resets!==4'hf || dut.start!==0)
                $fatal(1,"FAIL: asynchronous cancellation");
            rst_n=1;
        end
    endtask
    task automatic settle_sweeps;
        integer n;
        begin
            // At most17 commands * (64bits + overhead) *480ns ~0.56ms/sweep.
            for(n=0;n<100000;n=n+1) @(negedge clk);
        end
    endtask
    task automatic expect_good;
        integer n;
        begin
            n=0;
            while(!tx_qualified && n<100000) begin @(negedge clk);n=n+1;end
            if(!tx_qualified || !status_valid || !link_up || link_speed!=2 || !full_duplex || phy_id!=id_value)
                $fatal(1,"FAIL: valid gigabit qualification");
            if(tx_delay_raw!=tx_value || rx_delay_raw!=rx_value || physr_raw!=physr_value || speed_raw!=speed_value)
                $fatal(1,"FAIL: raw diagnostics torn/wrong");
            wait(transport_resets==0);
        end
    endtask
    task automatic expect_bad;
        begin
            settle_sweeps();
            if(tx_qualified || transport_resets!==4'hf) $fatal(1,"FAIL: bad PHY released transport");
        end
    endtask
    integer j;
    reg [31:0] writes_before;
    initial begin
        #100;rst_n=1;
        wait(dut.management_go);
        for(j=1;j<=3;j=j+1) begin
            @(negedge mdc);#2;
            if(dut.mdio_rst!==(j<3) || dut.start) $fatal(1,"FAIL: three-edge MDIO release");
        end
        expect_good();
        if(dut.settle_done || bmcr_writes!=1 || page!=0) $fatal(1,"FAIL: first sweep/fallback/page restore");
        // Same epoch: downshift although partner remains gigabit capable.
        physr_value=16'h001c;speed_value=16'h0010;expect_bad();
        if(!status_valid || !link_up || link_speed!=1) $fatal(1,"FAIL: real100M observation");
        physr_value=16'h000c;speed_value=0;expect_bad();
        if(!link_up || link_speed!=0) $fatal(1,"FAIL: real10M observation");
        physr_value=16'h002c;speed_value=16'h0020;expect_good();
        physr_value=16'h0028;expect_bad(); // real-time link drops, BMSR still high
        physr_value=16'h0024;expect_bad(); // half duplex
        physr_value=16'h003c;speed_value=16'h0030;expect_bad(); // reserved
        physr_value=16'h002c;speed_value=16'h0010;expect_bad(); // two status paths disagree
        speed_value=16'h0020;expect_good();
        bmsr_value=16'h0004;expect_bad(); // AN not complete
        bmsr_value=16'h0024;expect_good();
        tx_value=16'ha481;expect_bad(); // no TX delay for same-phase ODDR
        if(!status_valid || tx_delay_raw!=tx_value) $fatal(1,"FAIL: delay diagnostic");
        tx_value=16'ha581;rx_value=16'h0095;expect_good(); // RX delay does not gate TX
        // Bad TA at every important read, including page restoration.
        for(j=0;j<10;j=j+1) begin
            case(j)
                0: begin fail_page=0;fail_address=2;end
                1: begin fail_page=0;fail_address=3;end
                2: begin fail_page=0;fail_address=1;end
                3: begin fail_page=16'hd08;fail_address=17;end
                4: begin fail_page=16'hd08;fail_address=21;end
                5: begin fail_page=16'ha43;fail_address=26;end
                6: begin fail_page=0;fail_address=31;end
                7: begin fail_page=16'ha43;fail_address=18;end
                8: begin fail_page=16'ha43;fail_address=31;end
                9: begin fail_page=16'hd08;fail_address=31;end
            endcase
            fail_read=1;expect_bad();
            if(status_valid) $fatal(1,"FAIL: failed TA marked valid");
            fail_read=0;expect_good();
        end
        id_value=32'h001cc915;expect_bad();if(status_valid) $fatal(1,"FAIL: wrong model valid");
        id_value=0;expect_bad();id_value=32'hffffffff;expect_bad();
        id_value=32'h001cc916;expect_good();
        ignore_page_write=1;expect_bad();ignore_page_write=0;expect_good();
        // No extra BMCR restarts across errors/recovery in same epoch.
        if(bmcr_writes!=1) $fatal(1,"FAIL: gratuitous AN restart");
        // Fail only the final page0 readback, after a fully good paged sweep.
        wait(page==16'ha43 && framing && slave.address==18 && index==20);
        fail_page=0;fail_address=31;fail_read=1;
        expect_bad();if(status_valid) $fatal(1,"FAIL: restore failure accepted");
        fail_read=0;expect_good();
        // Reset in a paged read body: first new sweep must reselect page0.
        wait(page==16'hd08 && framing && index==20);writes_before=bmcr_writes;
        reset_phy();expect_good();
        if(bmcr_writes!=writes_before+1) $fatal(1,"FAIL: reset BMCR count");
        @(negedge clk);clock_running=0;reset_phy();#157;
        if(phy_rst_n || tx_qualified || !dut.mdio_rst) $fatal(1,"FAIL: stopped clock reset");
        clock_running=1;expect_good();
        // Wrong chip at cold start must not receive the BMCR restart write.
        id_value=32'h001cc915;writes_before=bmcr_writes;reset_phy();expect_bad();
        if(bmcr_writes!=writes_before) $fatal(1,"FAIL: BMCR before ID validation");
        id_value=32'h001cc916;expect_good();
        respond=0;reset_phy();wait(dut.settle_done);settle_sweeps();
        if(!phy_init_done || tx_qualified || status_valid || link_up) $fatal(1,"FAIL: fallback is not qualification");
        respond=1;expect_good();
        reset_phy();@(posedge clk);#1;reset_phy();expect_good();
        $display("PASS: phy_qualification ID/pages/delay/actual10-100-1000/downshift/link/TA/fallback/reset/barrier");
        $finish;
    end
    initial begin #100000000;$fatal(1,"FAIL: PHY qualification timeout");end
endmodule
