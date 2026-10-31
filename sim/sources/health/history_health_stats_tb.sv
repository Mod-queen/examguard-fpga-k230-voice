`timescale 1ns/1ps
module history_health_stats_tb;
    reg ui_clk=0,ui_rst=1,eth_clk=0,eth_rst=1;
    always #5 ui_clk=~ui_clk;
    always #4 eth_clk=~eth_clk;
    reg request_fire=0,result_fire=0,result_ok=1;
    reg [2:0] result_code=0,pending_windows=0;
    reg result_valid=0,out_valid=0,axi_fault=0,pixel_fault=0,hr_fault=0;
    reg [31:0] frames_committed=1011,frames_failed=0;
    reg pixel_packet_fire=0,hr_packet_fire=0,packet_stall=0,udp_fault=0;
    reg [31:0] udp_sent=45333,udp_dropped=0;
    wire [255:0] ui_stats;wire [127:0] eth_stats;
    history_health_stats dut(.*);
    // Real telemetry CDC plus status serializer, not just concatenation oracle.
    reg clk=0,rst=1;always #10 clk=~clk;
    wire [1023:0] report_data;
    wire uart_txd;
    evidence_health_telemetry #(.ENABLE_PHY_HEALTH(1)) telemetry(
        .clk(clk),.system_rst(rst),.control_rst(rst),.cap_clk(ui_clk),.cap_rst(ui_rst),
        .ui_clk(ui_clk),.ui_rst(ui_rst),.eth_clk(eth_clk),.eth_rst(eth_rst),
        .device_id(32'd1),.boot_id(32'd6),.session_id(32'd1),.time_ms(64'd102000),
        .boot_exhausted(1'b0),.id_exhausted(1'b0),.request_enable(1'b1),
        .fsm_requests(4'd0),.source_occupancy(4'd0),.source_high_water(4'd1),
        .source_accepted(32'd10),.source_rejected(32'd0),.source_delivered(32'd10),
        .cap_stats(256'd0),.ui_stats(ui_stats),.eth_stats(eth_stats),.phy_summary(32'h010002fe),
        .report_data(report_data),.flags(),.cancel_epochs(),.blocked_requests());
    reg status_valid=0;
    status_uart_tx #(.ENABLE_TIMER(1),.ENABLE_EVIDENCE_HEALTH(1),.STATUS_PERIOD_CYCLES(100000)) serializer(
        .clk(clk),.rst(rst),.status_valid(status_valid),.status_frame_id(32'd6120),.status_stage_id(4'd3),
        .status_risk_level(4'd0),.status_zone_id(4'd0),.status_timestamp(32'd102000),.status_event_code(8'd0),
        .status_motion_pickup(8'd0),.status_motion_operation(8'd0),.status_motion_forbidden(8'd0),
        .event_device_id(32'd1),.event_boot_id(32'd6),.event_session_id(32'd1),.event_uid(64'd1),.event_seq(8'd1),
        .health_flags(8'd0),.remaining_s(16'd2660),.exam_duration_s(16'd2700),.evidence_health_data(report_data),
        .uart_txd(uart_txd),.uart_busy(),.stream_valid(),.stream_last(),.stream_data(),.stream_ready(1'b0));
    task automatic pulse_result(input integer ok,input integer code);
        begin
            @(negedge ui_clk);result_fire=1;result_ok=ok;result_code=code;
            @(negedge ui_clk);result_fire=0;
        end
    endtask
    integer out_file,uart_bytes=0;
    reg [7:0] uart_byte;
    initial begin
        out_file=$fopen("history_health_uart.hex","w");
        wait(!rst);
        forever begin
            @(negedge uart_txd);#13020;
            for(integer b=0;b<8;b=b+1) begin uart_byte[b]=uart_txd;#8680;end
            if(uart_txd!==1) $fatal(1,"FAIL: health UART stop");
            $fdisplay(out_file,"%02x",uart_byte);uart_bytes=uart_bytes+1;
        end
    end
    initial begin
        repeat(5) @(negedge ui_clk);ui_rst=0;eth_rst=0;rst=0;
        @(negedge ui_clk);request_fire=1;pending_windows=3;pixel_packet_fire=1;hr_packet_fire=1;
        @(negedge ui_clk);request_fire=0;pixel_packet_fire=0;hr_packet_fire=0;
        pulse_result(1,0);pulse_result(0,4);
        if(ui_stats[255:224]!==32'h80000303 || ui_stats[223:192]!=1 || ui_stats[191:160]!=2 ||
           ui_stats[159:128]!=1011 || ui_stats[95:64]!=1 || ui_stats[63:32]!=1 || ui_stats[31:0]!=2)
            $fatal(1,"FAIL: canonical UI stats word placement %h",ui_stats);
        if(eth_stats!=={32'd0,32'd45333,32'd0,32'd0}) $fatal(1,"FAIL: canonical eth stats word placement");
        @(negedge eth_clk);packet_stall=1;udp_fault=1;udp_dropped=7;#1;
        if(eth_stats!=={32'd3,32'd45333,32'd7,32'd0}) $fatal(1,"FAIL: eth flags/data packing");
        @(negedge eth_clk);packet_stall=0;udp_fault=0;udp_dropped=0;
        wait(report_data[383:128]==ui_stats && report_data[127:32]==eth_stats[127:32]);
        repeat(5) @(negedge clk);status_valid=1;@(negedge clk);status_valid=0;
        wait(uart_bytes==320);repeat(1000) @(negedge clk);$fclose(out_file);
        // Independent reset domains and saturation, not natural wrapping.
        @(negedge ui_clk);dut.packets_serialized=32'hfffffffe;pixel_packet_fire=1;hr_packet_fire=1;
        @(negedge ui_clk);pixel_packet_fire=0;hr_packet_fire=0;
        if(ui_stats[31:0]!=32'hffffffff) $fatal(1,"FAIL: two packet saturation");
        ui_rst=1;repeat(3) @(negedge ui_clk);
        if(ui_stats[223:160] || ui_stats[95:0] || eth_stats[95:64]!=45333)
            $fatal(1,"FAIL: local counters reset crossed domains");
        $display("PASS: history_health_stats canonicalWords/reservedZero/counters/dualPacketSaturation/independentReset/realUART320");$finish;
    end
    initial begin #50000000;$fatal(1,"FAIL: history stats UART timeout");end
endmodule
