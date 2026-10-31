`timescale 1ns/1ps
module cdc2_level_tb;
    reg loc_clk50m=0,pixelclk=0,eth_clk125=0;
    reg run_control=1,run_pixel=1,run_eth=1;
    always #10 if(run_control)loc_clk50m=~loc_clk50m;
    always #7 if(run_pixel)pixelclk=~pixelclk;
    always #4 if(run_eth)eth_clk125=~eth_clk125;
    reg status_rst_50m=1,status_rst_pixel=1,evidence_eth_rst=1;
    reg operator_mute=0,profile_known=0,profile_valid=0,profile_default_mute=0;
    reg control_rst=1,link_ready_sync=0;
    wire buzzer_mute_pixel,tx_qualified,mac_rst,mute_source;
    cdc2_actual_levels dut(.*);
    reg in_valid=0,in_last=0;
    reg [7:0] in_data=0;
    wire in_ready,tx_en_pulse,protocol_fault,payload_req,tx_done;
    wire [15:0] data_length;
    wire [7:0] payload_data,gmii_txd;
    wire gmii_txen,gmii_tx_clk;
    wire [31:0] packets_sent,packets_dropped;
    evidence_packet_udp_bridge #(.MAX_PACKET_BYTES(16),.REQUIRE_TX_QUALIFIED(1)) bridge(
        .clk(eth_clk125),.rst(evidence_eth_rst),.*);
    eth_udp_tx_gmii mac(.clk125m(eth_clk125),.reset_p(mac_rst),.tx_en_pulse(tx_en_pulse),.tx_done(tx_done),
        .dst_mac(48'h112233445566),.src_mac(48'haabbccddeeff),.dst_ip(32'hc0a80102),.src_ip(32'hc0a80101),
        .dst_port(16'd6102),.src_port(16'd6102),.data_length(data_length),.payload_req_o(payload_req),.payload_dat_i(payload_data),
        .gmii_tx_clk(gmii_tx_clk),.gmii_txen(gmii_txen),.gmii_txd(gmii_txd));
    integer starts=0,checks=0;
    reg [31:0] video_progress=0;
    always @(posedge eth_clk125) begin
        if(!evidence_eth_rst) video_progress<=video_progress+1;
        if(!evidence_eth_rst && tx_en_pulse) starts=starts+1;
        if(!evidence_eth_rst && !tx_qualified && tx_en_pulse)$fatal(1,"FAIL: unqualified packet start");
    end
    task automatic byte_in(input [7:0] value,input last);
        begin
            @(negedge eth_clk125);in_valid=1;in_last=last;in_data=value;
            @(posedge eth_clk125);while(!in_ready)@(posedge eth_clk125);
            @(negedge eth_clk125);in_valid=0;in_last=0;
        end
    endtask
    task automatic packet(input integer n);
        integer i;begin for(i=0;i<n;i=i+1)byte_in(i,i==n-1);end
    endtask
    task automatic stable_mute(input bit expected);
        begin
            repeat(5)@(negedge loc_clk50m);
            repeat(4)@(negedge pixelclk);
            if(buzzer_mute_pixel!==expected)$fatal(1,"FAIL: stable mute profile/operator result");
            checks=checks+1;
        end
    endtask
    integer i,previous_starts;
    reg [31:0] before_video;
    initial begin
        repeat(6)@(negedge loc_clk50m);
        status_rst_50m=0;status_rst_pixel=0;evidence_eth_rst=0;control_rst=0;
        stable_mute(0);
        // With source clock stopped, combinational profile/operator changes
        // must not leak to destination despite its clock continuing.
        run_control=0;operator_mute=1;
        repeat(6)@(negedge pixelclk);
        if(mute_source!==0 || buzzer_mute_pixel!==0)$fatal(1,"FAIL: unregistered mute leak");
        operator_mute=0;profile_known=1;profile_valid=1;profile_default_mute=1;
        repeat(6)@(negedge pixelclk);
        if(buzzer_mute_pixel!==0)$fatal(1,"FAIL: profile combinational leak");
        run_control=1;stable_mute(1);
        operator_mute=1;stable_mute(0);
        profile_known=0;stable_mute(1);
        profile_valid=0;profile_known=1;stable_mute(1);
        profile_valid=1;stable_mute(0);
        // Destination clock can stop: source changes latch without changing
        // old destination state; ordinary synchronization resumes afterwards.
        @(negedge pixelclk);run_pixel=0;operator_mute=0;
        repeat(5)@(negedge loc_clk50m);
        if(mute_source!==1 || buzzer_mute_pixel!==0)$fatal(1,"FAIL: stopped pixel behavior");
        run_pixel=1;stable_mute(1);
        status_rst_pixel=1;repeat(3)@(negedge pixelclk);
        if(buzzer_mute_pixel!==0)$fatal(1,"FAIL: pixel reset");
        status_rst_pixel=0;stable_mute(1);
        for(i=0;i<40;i=i+1)begin
            operator_mute=i[0];profile_default_mute=i[1];profile_known=i[2];profile_valid=i[3];
            stable_mute(i[0]^(i[1]&&i[2]&&i[3]));
        end
        packet(3);if(packets_sent || starts)$fatal(1,"FAIL: offline start");
        link_ready_sync=1;wait(tx_qualified);repeat(3)@(negedge eth_clk125);
        packet(5);wait(packets_sent==1);
        // Actual source register + top synchronizer drives bridge/MAC. Drop
        // during header; no shared video reset, old packet never replays.
        packet(16);wait(gmii_txen);repeat(8)@(negedge eth_clk125);
        link_ready_sync=0;wait(!tx_qualified);repeat(5)@(negedge eth_clk125);
        if(gmii_txen || packets_sent!=1 || packets_dropped!=2 || protocol_fault)$fatal(1,"FAIL: qualified pipeline abort");
        before_video=video_progress;repeat(100)@(negedge eth_clk125);
        if(video_progress-before_video!=100)$fatal(1,"FAIL: shared video stopped");
        previous_starts=starts;link_ready_sync=1;wait(tx_qualified);repeat(30)@(negedge eth_clk125);
        if(starts!=previous_starts)$fatal(1,"FAIL: old tail replay");
        packet(4);wait(packets_sent==2);
        // Reset assertion clears the source without a source clock. Eth may
        // also stop; its own reset is the existing barrier owner's responsibility.
        @(negedge loc_clk50m);run_control=0;control_rst=1;#2;
        if(dut.eth_phy_tx_qualified!==0)$fatal(1,"FAIL: stopped source reset");
        repeat(4)@(negedge eth_clk125);
        if(tx_qualified!==0)$fatal(1,"FAIL: reset qualification stale");
        control_rst=0;repeat(5)@(negedge eth_clk125);
        if(tx_qualified!==0)$fatal(1,"FAIL: source reset released without clock");
        run_control=1;wait(tx_qualified);
        packet(1);wait(packets_sent==3);
        $display("PASS: cdc2_levels actual source/pixel/eth blocks profile/operator/stopped clocks/reset/realMAC abort recovery checks=%0d sent=%0d drops=%0d",checks,packets_sent,packets_dropped);
        $finish;
    end
    initial begin #2000000;$fatal(1,"FAIL: CDC2 levels timeout");end
endmodule
