`timescale 1ns/1ps
// All actual serializers -> store-forward mux -> actual UART pin decoder.
// Fork source accepted records to an independently stalled evidence consumer
// and an ET log queue. No external/board serial access.
module transaction_uart_integration_tb #(parameter integer UART_CLOCK=50000000,WITH_RA=0,WITH_MAINT=0,WITH_BOARD=0);
    localparam integer BIT_NS=20*(UART_CLOCK/115200);
    reg clk=0,ev_clk=0,rst=1,transport_rst=1;
    always #10 clk=~clk;
    always #7 ev_clk=~ev_clk;
    localparam integer SOURCES=WITH_BOARD?7:WITH_MAINT?6:WITH_RA?5:4;
    wire [SOURCES-1:0] v,last,ready;
    wire [SOURCES*8-1:0] bytes;
    reg anchor_valid=0;
    wire anchor_ready;
    generate if(WITH_RA) begin: ra
        rtc_anchor_record tx(.clk(clk),.rst(rst),.result_valid(anchor_valid),.result_ready(anchor_ready),
            .result_error(3'd0),.anchor_device(32'd1),.anchor_boot(32'd7),.anchor_sequence(32'd1),
            .lower_ms(64'd100),.upper_ms(64'd110),.rtc_raw(72'h261002201820350000),
            .byte_valid(v[4]),.byte_last(last[4]),.byte_data(bytes[39:32]),.byte_ready(ready[4]));
    end endgenerate
    generate if(WITH_BOARD) begin: bm
        board_monitor_record #(.PERIOD_CYCLES(20000000)) tx(.clk(clk),.rst(rst),
            .monitor({1'b1,32'd1,64'h5550999055509770}),.monitor_valid(1'b1),
            .device_id(32'd1),.boot_id(32'd7),.seat_id(32'd6),.monotonic_ms(64'd1000),
            .straps_valid(1'b1),.switches(8'h85),.byte_valid(v[6]),.byte_last(last[6]),.byte_data(bytes[55:48]),.byte_ready(ready[6]));
    end endgenerate
    generate if(WITH_MAINT) begin: mr
        wire [735:0] payload={48'h4d5201010060,8'd0,8'd0,32'd10,32'd1,32'd7,32'd18,
            8'd1,32'd0,24'd0,256'd0,72'd0,16'h7fff,136'd0};
        maintenance_record tx(.clk(clk),.rst(rst),.result_valid(anchor_valid),.result_ready(),.payload(payload),
            .byte_valid(v[5]),.byte_last(last[5]),.byte_data(bytes[47:40]),.byte_ready(ready[5]));
    end endgenerate
    wire uart_txd,fault;
    wire [31:0] sent,dropped;
    reg status_valid=0;
    reg [7:0] code=0;
    wire status_busy;
    status_uart_tx #(.STREAM_OUTPUT(1),.ENABLE_TIMER(1),.ENABLE_EVIDENCE_HEALTH(1),.STATUS_PERIOD_CYCLES(10000)) status_tx(
        .clk(clk),.rst(rst),.status_valid(status_valid),.status_frame_id(32'd42),.status_stage_id(4'd3),.status_risk_level(4'd0),.status_zone_id(4'd0),.status_timestamp(32'd7000),.status_event_code(code),
        .status_motion_pickup(8'd0),.status_motion_operation(8'd0),.status_motion_forbidden(8'd0),.event_device_id(32'd1),.event_boot_id(32'd2),.event_session_id(32'd3),.event_uid(64'd4),.event_seq(8'd5),
        .health_flags(8'd0),.remaining_s(16'd2700),.exam_duration_s(16'd2700),.evidence_health_data({32'h01000001,992'd0}),.uart_txd(),.uart_busy(status_busy),
        .stream_valid(v[0]),.stream_last(last[0]),.stream_data(bytes[7:0]),.stream_ready(ready[0]));
    reg trigger=0;
    wire cfg_busy;
    config_ack_tx #(.STREAM_OUTPUT(1)) config_tx(.clk(clk),.rst(rst),.trigger(trigger),.version(8'd17),.status(3'd0),.busy(cfg_busy),.uart_txd(),
        .stream_valid(v[1]),.stream_last(last[1]),.stream_data(bytes[15:8]),.stream_ready(ready[1]));
    reg ev_start=0,ring_read_valid=0;
    wire ring_read_req,dump_busy;
    wire [6:0] ring_read_index;
    evidence_dump #(.STREAM_OUTPUT(1),.CAPTURE_LENGTH(2)) dump_tx(.ev_clk(ev_clk),.ev_rst(rst),.ev_start(ev_start),.ring_available(1'b1),
        .ring_read_valid(ring_read_valid),.ring_read_data({32'd42,32'd7000,4'd3,4'd0,4'd0,8'd80,8'd1,8'd2,8'd3,8'd4,8'd0,8'd7}),.ring_seq(8'd7),
        .ring_read_req(ring_read_req),.ring_read_index(ring_read_index),.busy(dump_busy),.uart_clk(clk),.uart_rst(rst),.uart_txd(),
        .stream_valid(v[2]),.stream_last(last[2]),.stream_data(bytes[23:16]),.stream_ready(ready[2]));
    always @(posedge ev_clk) if(rst) ring_read_valid<=0;else ring_read_valid<=ring_read_req;
    reg in_valid=0;
    reg [255:0] in_data=0;
    wire in_ready,a_valid,b_valid;
    wire [255:0] a_data,b_data;
    reg a_ready=0;
    wire b_ready;
    event_transaction_fork fork_inst(.clk(clk),.rst(transport_rst),.*);
    wire [2:0] occupancy;
    wire event_valid,event_ready;
    wire [255:0] event_data;
    assign b_ready=!transport_rst && occupancy<4;
    event_request_fifo #(.SOURCES(1),.DATA_WIDTH(256),.DEPTH(4)) log_queue(.clk(clk),.rst(rst),.request(b_valid && b_ready),.request_data(b_data),
        .accepted(),.rejected(),.event_valid(event_valid),.event_ready(event_ready),.event_data(event_data),.occupancy(occupancy),.high_water(),.accepted_count(),.rejected_count(),.delivered_count());
    event_transaction_log log_tx(.clk(clk),.rst(rst),.event_valid(event_valid),.event_data(event_data),.event_ready(event_ready),
        .byte_valid(v[3]),.byte_last(last[3]),.byte_data(bytes[31:24]),.byte_ready(ready[3]));
    uart_packet_mux #(.SOURCES(SOURCES),.CLK_FREQ_HZ(UART_CLOCK),.BAUD_RATE(115200)) mux(.clk(clk),.rst(rst),.in_valid(v),.in_last(last),.in_data(bytes),.in_ready(ready),.source_cancel({SOURCES{1'b0}}),
        .uart_txd(uart_txd),.protocol_fault(fault),.packets_sent(sent),.packets_dropped(dropped));
    function [255:0] record;
        input integer uid;
        begin record={32'hac750001,32'd5,32'd1,64'(uid),64'h12345678ffffffff+uid,8'(uid%4),8'd0,16'h3750};end
    endfunction
    integer evidence_count=0,et_count=0,al=0,ei=0,st=0,ev=0,eo=0,ca=0,ra_count=0,mr_count=0,bm_count=0,n,fd,bitnum;
    reg [7:0] ch;
    string line="",expected;
    reg expect_ei=0;
    always @(posedge clk) if(!transport_rst && a_valid && a_ready) begin
        if(a_data!==record(evidence_count+1)) $fatal(1,"FAIL: fork evidence identity/order");
        evidence_count=evidence_count+1;
    end
    initial forever begin
        @(negedge uart_txd);#(BIT_NS*3/2);
        for(bitnum=0;bitnum<8;bitnum=bitnum+1) begin ch[bitnum]=uart_txd;#(BIT_NS);end
        if(!uart_txd) $fatal(1,"FAIL: integrated UART framing");
        if(ch==10) begin
            $fwrite(fd,"%s\n",line);$fflush(fd);
            if(expect_ei && line.substr(0,2)!="EI,") $fatal(1,"FAIL: AL/EI association split by another source");
            if(line.substr(0,2)=="ET,") begin
                expected=$sformatf("ET,%064x",record(et_count+1));expected=expected.toupper();
                if(line!=expected) $fatal(1,"FAIL: integrated ET identity %s",line);
                et_count=et_count+1;
            end else if(line.substr(0,2)=="ST,") begin if(line.len()!=319) $fatal(1,"FAIL: truncated ST");st=st+1;end
            else if(line=="AL,0000000042,0000007000,3,0,0,080") begin al=al+1;expect_ei=1;end
            else if(line=="EI,00000001,00000002,00000003,0000000000000004,005") begin ei=ei+1;expect_ei=0;end
            else if(line=="CA,017,0") ca=ca+1;
            else if(line.substr(0,2)=="EV,") begin if(line.len()!=61) $fatal(1,"FAIL: truncated EV");ev=ev+1;end
            else if(line=="EO,007,002") eo=eo+1;
            else if(WITH_RA && line.substr(0,2)=="RA,") begin
                if(line.len()!=131) $fatal(1,"FAIL: mixed RA length");
                ra_count=ra_count+1;
            end
            else if(WITH_MAINT && line.substr(0,2)=="MR,") begin
                if(line.len()!=195) $fatal(1,"FAIL: mixed MR length");
                mr_count=mr_count+1;
            end
            else if(WITH_BOARD && line.substr(0,2)=="BM,") begin
                if(line.len()!=131) $fatal(1,"FAIL: mixed BM length");bm_count=bm_count+1;
            end
            else $fatal(1,"FAIL: interleaved malformed UART line %s",line);
            line="";
        end else line={line,ch};
    end
    initial begin
        fd=$fopen("transaction_uart.txt","w");if(!fd) $fatal(1,"FAIL: UART trace open");
        repeat(8) @(negedge clk);rst=0;transport_rst=0;status_valid=1;
        wait(mux.active && mux.owner==0 && mux.read_index>=10);
        if(WITH_RA) begin
            @(negedge clk);anchor_valid=1;@(negedge clk);anchor_valid=0;
        end
        @(negedge clk);code=80;trigger=1;@(negedge clk);trigger=0;
        @(negedge ev_clk);ev_start=1;@(negedge ev_clk);ev_start=0;
        fork
            begin
                for(n=1;n<=12;n=n+1) begin
                    @(negedge clk);in_valid=1;in_data=record(n);
                    @(posedge clk);while(!in_ready) @(posedge clk);
                    @(negedge clk);in_valid=0;
                end
            end
            begin
                // Slow evidence branch cannot duplicate the fast log branch.
                repeat(1000) @(negedge clk);a_ready=1;
            end
        join
        wait(evidence_count==12 && et_count==12 && al==1 && ei==1 && ca==1 && ev==2 && eo==1 && st>0 && (!WITH_RA || ra_count==1) && (!WITH_MAINT || mr_count==1) && (!WITH_BOARD || bm_count==1));
        if(fault || dropped) $fatal(1,"FAIL: integrated UART mux fault/drop");
        // Cancel a fork with only its log side consumed; already accepted ET
        // survives in system-owned log buffers and is not a successful window.
        @(negedge clk);a_ready=0;in_valid=1;in_data=record(13);
        @(posedge clk);while(!in_ready) @(posedge clk);
        @(negedge clk);in_valid=0;wait(!b_valid);@(negedge clk);transport_rst=1;
        repeat(10) @(negedge clk);transport_rst=0;wait(et_count==13);
        if(evidence_count!=12) $fatal(1,"FAIL: cancelled evidence delivery replayed");
        $fclose(fd);
        $display("PASS: transaction_uart_integration actual ST320/AL-EI atomic/CA/EV-EO/ET13 sources one UART; fork12 + cancelled13 log retained");$finish;
    end
    initial begin #1000000000;$fatal(1,"FAIL: UART integration timeout et=%0d evidence=%0d ev=%0d eo=%0d al/ei=%0d/%0d",et_count,evidence_count,ev,eo,al,ei);end
endmodule
