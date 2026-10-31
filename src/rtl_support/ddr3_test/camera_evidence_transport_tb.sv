`timescale 1ns/1ps
// Actual FSM -> local identity/context/queue -> camera/time/DDR -> packet CDC ->
// actual Ethernet. Small images/behavior AXI memory, four real clock domains.
module camera_evidence_transport_tb #(parameter LIFECYCLE=0,HEALTH_OUTPUT=0,TRANSACTION_UART=0);
    reg arst=1,system_rst=1,control_clk=0,cap_clk=0,clk=0,eth_clk=0;
    always #10 control_clk=~control_clk;
    always #7 cap_clk=~cap_clk;
    always #5 clk=~clk;
    always #4 eth_clk=~eth_clk;
    wire [3:0] resets;
    wire control_rst=resets[0],cap_rst=resets[1],rst=resets[2],eth_rst=resets[3];
    evidence_reset_barrier reset_barrier(.arst(arst),.clocks({eth_clk,clk,cap_clk,control_clk}),.resets(resets));
    reg tick=0,face=0,start=0,submit=0,object_pulse=0,gaze=0,frame_pulse=0;
    reg [2:0] object_class=1;
    wire fsm_rst=LIFECYCLE ? system_rst : control_rst;
    wire [2:0] stage;
    wire [3:0] request;
    wire [63:0] request_data;
    exam_fsm #(.SELFCHECK_TICKS(1),.GAZE_TURN_FRAMES(1),.PARALLEL_EVENTS(1)) fsm(
        .clk(control_clk),.rst(fsm_rst),.tick_1s(tick),.frame_pulse(frame_pulse),.face_pulse(face),.face_ok(1'b1),.face_id(2'd1),
        .object_pulse(object_pulse),.object_class(object_class),.activity_global(8'd20),.active_cells(16'd2000),.luma_avg(8'd120),
        .gaze_pulse(gaze),.gaze_away(1'b1),.gaze_present(1'b1),.start_pulse(start),.submit_pulse(submit),.ack_pulse(1'b0),.timeout_pulse(1'b0),
        .stage_id(stage),.risk_level(),.event_code(),.event_seq(),.remaining_s(),.authorized_id(),.new_event(),
        .debug_luma(),.debug_base(),.debug_flags(),.debug_gaze_cnt(),.event_request(request),.event_request_data(request_data));
    wire session_start,session_end,session_active;
    wire [31:0] device_id,boot_id,session_id;
    wire [63:0] time_ms;
    wire request_rst,request_enable,boot_exhausted;
    generate if(LIFECYCLE) begin: epoch_identity
        evidence_epoch_identity identity(.clk(control_clk),.system_rst(system_rst),.transport_rst(control_rst),.ms_tick(1'b1),
            .device_straps(32'hac750001),.session_start(session_start),.session_end(session_end),.session_active(session_active),
            .device_id(device_id),.boot_id(boot_id),.session_id(session_id),.time_ms(time_ms),.request_rst(request_rst),
            .request_enable(request_enable),.boot_exhausted(boot_exhausted));
    end else begin: legacy_identity
    assign request_rst=control_rst;
    assign request_enable=1'b1;
    assign boot_exhausted=1'b0;
    event_identity identity(.clk(control_clk),.rst(control_rst),.ms_tick(1'b1),.device_straps(32'hac750001),.boot_pulse(1'b0),
        .session_start(session_start),.session_end(session_end),.session_active(session_active),.device_id(device_id),.boot_id(boot_id),.session_id(session_id),
        .time_ms(time_ms),.boot_event(),.session_event(),.started_count(),.ignored_start_count());
    end endgenerate
    wire [3:0] aligned_request;
    wire [63:0] aligned_data,aligned_time_ms;
    wire [31:0] aligned_device,aligned_boot,aligned_session;
    exam_event_context context_inst(.clk(control_clk),.rst(fsm_rst),.stage(stage),.request(request & {4{request_enable}}),.request_data(request_data),
        .device_id(device_id),.boot_id(boot_id),.session_id(session_id),.session_active(session_active),.time_ms(time_ms),
        .session_start(session_start),.session_end(session_end),.aligned_request(aligned_request),.aligned_data(aligned_data),.aligned_time_ms(aligned_time_ms),
        .aligned_device(aligned_device),.aligned_boot(aligned_boot),.aligned_session(aligned_session));
    wire queue_valid,queue_ready,event_valid,event_ready;
    wire [255:0] event_data;
    wire [255:0] queue_data;
    reg uart_trace_enable=0;
    wire uart_records_complete;
    reg deliver_events=0,drain_auth=0;
    wire [31:0] accepted_count,rejected_count,delivered_count;
    wire [3:0] source_occupancy,source_high_water;
    generate if(TRANSACTION_UART) begin: uart_observe
        wire fork_ready,log_valid,log_ready;
        wire [255:0] log_data;
        assign queue_ready=deliver_events ? fork_ready : drain_auth;
        event_transaction_fork fork_inst(.clk(control_clk),.rst(request_rst),.in_valid(queue_valid && deliver_events),.in_ready(fork_ready),.in_data(queue_data),
            .a_valid(event_valid),.a_ready(event_ready),.a_data(event_data),.b_valid(log_valid),.b_ready(log_ready),.b_data(log_data));
        wire bv,bl,br;
        wire [7:0] bd;
        wire log_input_ready;
        assign log_ready=uart_trace_enable && log_input_ready;
        event_transaction_log log_inst(.clk(control_clk),.rst(control_rst),.event_valid(log_valid && uart_trace_enable),.event_data(log_data),.event_ready(log_input_ready),
            .byte_valid(bv),.byte_last(bl),.byte_data(bd),.byte_ready(br));
        wire uart_txd;
        uart_packet_mux #(.SOURCES(1)) mux(.clk(control_clk),.rst(control_rst),.in_valid(bv),.in_last(bl),.in_data(bd),.in_ready(br),.source_cancel(1'b0),
            .uart_txd(uart_txd),.protocol_fault(),.packets_sent(),.packets_dropped());
        integer uart_fd,b,records=0;
        assign uart_records_complete=records==4;
        reg [7:0] ch;
        initial begin
            uart_fd=$fopen("transaction_camera_uart.txt","w");if(!uart_fd) $fatal(1,"FAIL: camera UART open");
            forever begin
                @(negedge uart_txd);#13020;
                for(b=0;b<8;b=b+1) begin ch[b]=uart_txd;#8680;end
                if(!uart_txd) $fatal(1,"FAIL: camera transaction UART framing");
                $fwrite(uart_fd,"%c",ch);$fflush(uart_fd);
                if(ch==10) records=records+1;
            end
        end
    end else begin: no_uart
        assign uart_records_complete=1'b1;
        assign event_valid=queue_valid && deliver_events;
        assign queue_ready=deliver_events ? event_ready : drain_auth;
        assign event_data=queue_data;
    end endgenerate
    event_transaction_queue #(.DEPTH(8)) queue(.clk(control_clk),.rst(request_rst),.request(aligned_request),.request_data(aligned_data),
        .device_id(aligned_device),.boot_id(aligned_boot),.session_id(aligned_session),.request_time_ms(aligned_time_ms),
        .accepted(),.rejected(),.event_valid(queue_valid),.event_ready(queue_ready),.event_data(queue_data),.occupancy(source_occupancy),.high_water(source_high_water),
        .accepted_count(accepted_count),.rejected_count(rejected_count),.delivered_count(delivered_count),.id_exhausted());
    reg enable=1,de=0,sof=0;
    reg [11:0] x=0,y=0;
    reg [31:0] frame_id=0;
    wire [7:0] pixel_r=8'hf0,pixel_g=8'h80,pixel_b=8'h28;
    wire [31:0] rejected_unknown,rejected_stale,frames_committed,frames_failed,read_errors;
    wire [31:0] packets_sent,results_sent,udp_packets_sent,udp_packets_dropped;
    wire [255:0] cap_health_stats,ui_health_stats;
    wire [127:0] eth_health_stats;
    wire packet_fault,udp_fault,tx_en_pulse,payload_req,tx_done;
    reg pause_udp=0;
    wire ethernet_start=tx_en_pulse && !pause_udp;
    wire ethernet_done;
    assign tx_done=ethernet_done;
    wire [15:0] data_length;
    wire [7:0] payload_data,gmii_txd;
    wire gmii_txen,gmii_tx_clk;
    `include "axi_frame_tb_wires.vh"
    reg hold_b=0,inject_b=0,inject_r=0;
    camera_evidence_transport #(.SRC_WIDTH(8),.SRC_HEIGHT(8),.SAMPLE_STRIDE(4),.FRAME_INTERVAL(1),
        .PRE_FRAMES(1),.POST_FRAMES(1),.RING_FRAMES(4),.FIFO_DEPTH(16),.EVENT_DEPTH(2),.PACKET_FIFO_DEPTH(16),.CHUNK_PIXELS(3),.BASE_ADDR(4080)) transport(
        .control_time_ms(time_ms),.tx_qualified(1'b1),.*);
    axi_frame_slave_model memory(.rst(arst || rst),.*);
    wire [1023:0] health_report;
    wire [23:0] health_flags;
    wire [31:0] health_cancels,health_blocked;
    generate if(HEALTH_OUTPUT) begin: observe_health
        evidence_health_telemetry health_inst(.clk(control_clk),.system_rst(system_rst),.control_rst(control_rst),
            .cap_clk(cap_clk),.cap_rst(cap_rst),.ui_clk(clk),.ui_rst(rst),.eth_clk(eth_clk),.eth_rst(eth_rst),
            .device_id(device_id),.boot_id(boot_id),.session_id(session_id),.time_ms(time_ms),.boot_exhausted(boot_exhausted),.id_exhausted(1'b0),.request_enable(request_enable),
            .fsm_requests(request),.source_occupancy(source_occupancy),.source_high_water(source_high_water),
            .source_accepted(accepted_count),.source_rejected(rejected_count),.source_delivered(delivered_count),
            .cap_stats(cap_health_stats),.ui_stats(ui_health_stats),.eth_stats(eth_health_stats),.report_data(health_report),.flags(health_flags),
            .cancel_epochs(health_cancels),.blocked_requests(health_blocked));
    end endgenerate
    eth_udp_tx_gmii ethernet(.clk125m(eth_clk),.reset_p(eth_rst),.tx_en_pulse(ethernet_start),.tx_done(ethernet_done),
        .dst_mac(48'hffffffffffff),.src_mac(48'h020000000002),.dst_ip(32'hc0a80003),.src_ip(32'hc0a80002),
        .dst_port(16'd6102),.src_port(16'd5000),.data_length(data_length),.payload_req_o(payload_req),.payload_dat_i(payload_data),
        .gmii_tx_clk(gmii_tx_clk),.gmii_txen(gmii_txen),.gmii_txd(gmii_txd));
    integer fd,meta_fd,frame_number,xx,yy,wire_packets=0;
    reg previous_en=0;
    reg trace_enabled=!LIFECYCLE;
    reg [63:0] collision_time;
    always @(posedge eth_clk) if(eth_rst) previous_en<=0;else begin
        previous_en<=gmii_txen;
        if(gmii_txen && trace_enabled) $fwrite(fd,"%02x",gmii_txd);
        if(previous_en && !gmii_txen && trace_enabled) begin $fwrite(fd,"\n");$fflush(fd);wire_packets=wire_packets+1;end
    end
    always @(posedge cap_clk) if(!cap_rst && sof && transport.frame_enable) begin
        $fwrite(meta_fd,"%0d %016x\n",frame_id,transport.frame_meta[63:0]);$fflush(meta_fd);
    end
    always @(posedge control_clk) if(LIFECYCLE && !request_rst && queue_valid && queue_ready && trace_enabled)
        $display("LIFECYCLE_EVENT uid=%0d time=%016x code=%02x",event_data[159:96],event_data[95:32],event_data[7:0]);
    task frame;
        input integer id;
        begin
            @(negedge cap_clk);frame_id=id;sof=1;
            for(yy=0;yy<8;yy=yy+1) for(xx=0;xx<8;xx=xx+1) begin
                de=1;x=xx;y=yy;@(negedge cap_clk);sof=0;
            end
            de=0;repeat(80) @(negedge cap_clk);
        end
    endtask
    generate if(!LIFECYCLE) begin: normal_run
    initial begin
        fd=$fopen("transport_gmii.hex","w");meta_fd=$fopen("transport_frame_meta.txt","w");
        if(!fd || !meta_fd) $fatal(1,"FAIL: transport trace open");
        repeat(5) @(negedge control_clk);arst=0;wait(resets==0);
        // Prime an OLD auth event and hold a DDR B response; reset ALL masters,
        // arbiter-equivalent endpoint/memory, event/time and packet domains.
        @(negedge control_clk);tick=1;@(negedge control_clk);tick=0;face=1;
        @(negedge control_clk);face=0;deliver_events=1;
        wait(transport.client.evidence.dispatcher.active);wait(transport.time_valid);
        hold_b=1;frame(99);wait(memory.responding);
        #1;arst=1;#3;arst=0;hold_b=0;deliver_events=0;
        wait(resets==0);repeat(15) @(negedge clk);
        if(frames_committed || transport.client.evidence.dispatcher.active || results_sent || wire_packets || queue_valid)
            $fatal(1,"FAIL: transport common reset leaked old B/event/window");
        @(negedge control_clk);legacy_identity.identity.time_ms=64'h12345678fffffff0;
        tick=1;@(negedge control_clk);tick=0;face=1;
        @(negedge control_clk);face=0;wait(queue_valid);
        @(negedge control_clk);drain_auth=1;@(negedge control_clk);drain_auth=0;
        start=1;@(negedge control_clk);start=0;
        wait(transport.time_valid);frame(0);wait(frames_committed==1);
        @(negedge control_clk);submit=1;object_pulse=1;gaze=1;frame_pulse=1;collision_time=time_ms;
        @(negedge control_clk);submit=0;object_pulse=0;gaze=0;frame_pulse=0;
        if(request!=15 || stage!=4) $fatal(1,"FAIL: transport source collision");
        repeat(8) @(negedge control_clk);
        if(accepted_count!=5 || rejected_count) $fatal(1,"FAIL: transport source admission");
        $display("TRANSPORT_EXPECTED source_time=%016x uid2..5 session1",collision_time);
        deliver_events=1;
        uart_trace_enable=1;
        frame_number=1;
        while(results_sent<4) begin frame(frame_number);frame_number=frame_number+1;end
        enable=0;wait(wire_packets==20);repeat(10) @(negedge eth_clk);
        if(packet_fault || udp_fault || frames_failed || read_errors || udp_packets_dropped || udp_packets_sent!=20 || session_id!=1 || session_active || delivered_count!=5)
            $fatal(1,"FAIL: full transport conservation");
        if(TRANSACTION_UART) begin: wait_uart
            wait(uart_records_complete);
            $display("PASS: camera_transaction_uart four-source accepted IDs exactly shared with GMII window packets");
        end
        $fclose(fd);$fclose(meta_fd);
        $display("PASS: camera_evidence_transport actualFSM/identity/camera/DDR/CDC/GMII 4windows 8frames32pixels20packets");$finish;
    end
    end endgenerate
    reg [31:0] old_boot;
    reg [63:0] old_time,new_time;
    task object_event;
        input integer cls;
        begin
            @(negedge control_clk);object_class=cls;object_pulse=1;
            @(negedge control_clk);object_pulse=0;
        end
    endtask
    task transport_cancel;
        begin
            old_boot=boot_id;old_time=time_ms;
            #1;arst=1;#3;arst=0;hold_b=0;pause_udp=0;
            wait(!request_rst);repeat(8) @(negedge control_clk);
            if(boot_id!=old_boot+1 || session_id!=1 || !session_active || stage!=3 || time_ms<=old_time ||
                queue_valid || results_sent || transport.client.evidence.dispatcher.active || transport.packet_cdc.dst_valid)
                $fatal(1,"FAIL: transport-only cancellation changed exam or leaked old epoch");
        end
    endtask
    generate if(LIFECYCLE) begin: lifecycle_run
    initial begin
        fd=$fopen("lifecycle_gmii.hex","w");meta_fd=$fopen("transport_frame_meta.txt","w");
        if(!fd || !meta_fd) $fatal(1,"FAIL: lifecycle trace open");
        repeat(5) @(negedge control_clk);system_rst=0;arst=0;wait(!request_rst);repeat(8) @(negedge control_clk);
        epoch_identity.identity.identity.time_ms=64'h12345678fffffff0;
        tick=1;@(negedge control_clk);tick=0;face=1;
        @(negedge control_clk);face=0;wait(queue_valid);
        @(negedge control_clk);drain_auth=1;@(negedge control_clk);drain_auth=0;start=1;
        @(negedge control_clk);start=0;wait(session_active);deliver_events=1;wait(transport.time_valid);
        // Cancel a held write response and an event while exam FSM remains EXAM.
        frame(0);wait(frames_committed==1);object_event(1);wait(transport.client.evidence.dispatcher.active);
        hold_b=1;frame(99);wait(memory.responding);transport_cancel();
        // Cancel a complete old packet held by a non-starting Ethernet sink.
        frame(1);wait(frames_committed==1);object_event(2);wait(transport.client.evidence.dispatcher.active);
        pause_udp=1;frame(2);wait(transport.udp_bridge.state==2);
        repeat(100) @(negedge clk);transport_cancel();
        // Pulse born on the final admission-reset edge must not leak into boot
        // allocated on restart. Also preserve stage tracking/session during reset.
        old_boot=boot_id;#1;arst=1;repeat(3) @(negedge control_clk);arst=0;
        wait(!control_rst);wait(epoch_identity.identity.startup==3'b100);
        @(negedge control_clk);object_class=3;object_pulse=1;
        @(negedge control_clk);object_pulse=0;wait(!request_rst);repeat(8) @(negedge control_clk);
        if(queue_valid || accepted_count || boot_id!=old_boot+1 || session_id!=1 || !session_active)
            $fatal(1,"FAIL: request born under reset escaped on release");
        // New UID1, same exam session, different boot; produce a real complete
        // window then a second independently rearmed object.
        trace_enabled=1;frame(3);wait(frames_committed==1);
        object_event(7);object_event(7);object_event(7);
        new_time=time_ms;object_event(1);wait(transport.client.evidence.dispatcher.active);
        $display("LIFECYCLE_EXPECTED boot=%0d session=1 uid1/2",boot_id);
        frame(4);wait(results_sent==1);wait(wire_packets==5);
        object_event(7);object_event(7);object_event(7);object_event(2);
        wait(transport.client.evidence.dispatcher.active);frame(5);wait(results_sent==2);wait(wire_packets==10);
        if(packet_fault || udp_fault || frames_failed || read_errors || boot_exhausted || accepted_count!=2 || delivered_count!=2 || session_id!=1 || !session_active)
            $fatal(1,"FAIL: lifecycle fresh window conservation");
        if(HEALTH_OUTPUT) begin
            wait(health_flags[6:4]==7 && health_report[63:32]==0 && health_report[95:64]==10 && health_report[319:288]==2);
            if(health_cancels!=3 || health_blocked!=1 || health_report[351:320]!=2 || health_report[287:256]!=3 || health_report[255:160]!=0 ||
                health_report[127:96]!=0 || health_report[895:864]!=2)
                $fatal(1,"FAIL: REAL transport health snapshot counts cancels=%0d blocked=%0d",health_cancels,health_blocked);
            $display("REAL_HEALTH_SUCCESS %0256x",health_report);
            // Real injected AXI B failure must appear as DDR write failure AND
            // failed window; successful pixel/UDP traffic cannot wash it away.
            trace_enabled=0;
            object_event(7);object_event(7);object_event(7);object_event(1);
            wait(transport.client.evidence.dispatcher.active);inject_b=1;frame(6);
            wait(frames_failed==1 && results_sent==3);inject_b=0;
            wait(health_flags[11] && health_report[255:224]==1 && health_report[191:160]==1);
            if(health_report[895:864]!=3) $fatal(1,"FAIL: real failed event source accepted count");
            $display("REAL_HEALTH_FAULT %0256x",health_report);
        end
        // Closing the exam while transport is reset must still close the
        // local session tracker. The flow request is cancelled, not replayed.
        trace_enabled=0;old_boot=boot_id;#1;arst=1;
        if(HEALTH_OUTPUT) begin
            repeat(2) @(negedge control_clk);
            if(health_flags[6:4] || health_report[639:0]!=0 || !health_flags[0]) $fatal(1,"FAIL: real transport cached stats survived cancellation");
            $display("REAL_HEALTH_RESET %0256x",health_report);
        end
        @(negedge control_clk);submit=1;@(negedge control_clk);submit=0;
        repeat(4) @(negedge control_clk);arst=0;wait(!request_rst);repeat(8) @(negedge control_clk);
        if(stage!=4 || session_active || session_id!=1 || boot_id!=old_boot+1 || queue_valid || accepted_count)
            $fatal(1,"FAIL: submit under transport reset lost session close/replayed flow event");
        if(HEALTH_OUTPUT) begin
            wait(health_flags[6:4]==7);
            if(health_cancels!=4 || health_blocked!=2 || health_report[639:0]!=0) $fatal(1,"FAIL: fresh zeroed real stats/cancel count");
            $display("REAL_HEALTH_RECOVER %0256x",health_report);
            $display("PASS: camera_health_integration real transport stats/current-epoch reset/blocked requests and cancellations");
        end
        $fclose(fd);$fclose(meta_fd);
        $display("PASS: camera_evidence_lifecycle in-exam reset/B-held/packet-held/admission-edge/newBoot-UID1/sameSession 2windows10packets");$finish;
    end
    end endgenerate
    initial begin #(TRANSACTION_UART ? 50000000 : 5000000);$fatal(1,"FAIL: camera transport timeout results=%0d packets=%0d stage=%0d boot=%0d rst=%b",results_sent,wire_packets,stage,boot_id,resets);end
endmodule
