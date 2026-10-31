`timescale 1ns/1ps
// Actual context -> actual camera client -> behavior AXI memory. Covers stale
// SOF rejection, recovery, and global reset of master AND memory during delayed
// B/held event. It does not simulate a real MIG or independently reset AXI.
module evidence_capture_context_tb #(parameter PACKET_SINK=0);
    reg arst=1,control_clk=0,cap_clk=0,clk=0;
    reg control_running=1;
    always #10 if(control_running) control_clk=~control_clk;
    always #7 cap_clk=~cap_clk;
    always #5 clk=~clk;
    reg [63:0] control_time_ms=64'h12345678fffffff0;
    wire control_rst,cap_rst,rst;
    reg sof=0,de=0,cap_enable=1;
    reg [31:0] frame_id=0;
    wire enable,time_valid;
    wire [63:0] time_ms;
    wire [95:0] frame_meta;
    wire [31:0] age_cycles,rejected_unknown,rejected_stale;
    evidence_capture_context #(.MAX_AGE_CYCLES(40)) context_inst(
        .ui_clk(clk),.ui_rst(rst),.frame_enable(enable),.*);
    always @(posedge control_clk) if(!control_rst) control_time_ms<=control_time_ms+1;
    reg [11:0] x=0,y=0;
    wire [7:0] pixel_r=8'hf0,pixel_g=8'h80,pixel_b=8'h28;
    reg event_valid=0;
    reg [255:0] event_data=0;
    wire event_ready;
    wire [31:0] cdc_accepted_count,cdc_delivered_count;
    wire [1:0] banks_occupied,occupancy,high_water;
    wire [31:0] frames_seen,frames_buffered,frames_sent,dropped_busy,dropped_invalid,dropped_disabled;
    wire [31:0] accepted_count,rejected_count,completed_count;
    wire out_valid,out_sof,out_last,out_deferred,result_valid,result_ok,result_deferred,commit_valid;
    wire [15:0] out_data;
    wire [95:0] out_meta,commit_meta;
    wire [255:0] out_event,result_event;
    wire [31:0] result_frames,frames_committed,frames_failed,windows_completed,read_errors,write_beats,read_beats;
    wire [1:0] commit_slot;
    reg allow_output=0;
    wire out_ready,result_ready;
    wire [31:0] packets_sent,results_sent;
    wire packet_fault;
    generate if(PACKET_SINK) begin: packet_sink
        wire tx_valid,tx_last;
        wire [7:0] tx_data;
        reg tx_ready=0;
        integer seed=32'hcafe,bytes=0,fd;
        initial begin
            fd=$fopen("camera_window_packets.hex","w");
            if(!fd) $fatal(1,"FAIL: camera packet trace open");
        end
        // Two chunks per 8-byte RGB565 frame plus an explicit result packet.
        evidence_window_packetizer #(.WIDTH(2),.HEIGHT(2),.CHUNK_PIXELS(3)) packetizer(
            .clk(clk),.rst(rst),.out_valid(out_valid),.out_sof(out_sof),.out_last(out_last),
            .out_data(out_data),.out_meta(out_meta),.out_event(out_event),.out_deferred(out_deferred),.out_ready(out_ready),
            .result_valid(result_valid),.result_ok(result_ok),.result_deferred(result_deferred),
            .result_event(result_event),.result_frames(result_frames),.result_ready(result_ready),
            .tx_valid(tx_valid),.tx_last(tx_last),.tx_data(tx_data),.tx_ready(tx_ready),
            .packets_sent(packets_sent),.results_sent(results_sent),.protocol_fault(packet_fault));
        always @(negedge clk) tx_ready=allow_output && (($random(seed)&7)!=0);
        always @(posedge clk) if(!rst && tx_valid && tx_ready) begin
            bytes=bytes+1;
            $fwrite(fd,"%02x",tx_data);
            if(tx_last) begin $fwrite(fd,"\n");$fflush(fd);end
        end
    end else begin: direct_sink
        assign out_ready=allow_output;
        assign result_ready=allow_output;
        assign packets_sent=0;
        assign results_sent=0;
        assign packet_fault=0;
    end endgenerate
    reg hold_b=0,inject_b=0,inject_r=0;
    `include "axi_frame_tb_wires.vh"
    camera_evidence_client #(.SRC_WIDTH(8),.SRC_HEIGHT(8),.SAMPLE_STRIDE(4),.FRAME_INTERVAL(1),
        .PRE_FRAMES(1),.POST_FRAMES(1),.RING_FRAMES(4),.FIFO_DEPTH(16),.EVENT_DEPTH(2),.BASE_ADDR(4080)) client(.*);
    // Global memory reset asserted immediately, release on same UI epoch.
    axi_frame_slave_model memory(.rst(arst || rst),.*);
    reg [95:0] captured_meta[0:15];
    integer xx,yy,pixels=0,results=0,commits=0,n;
    reg checking=0;
    localparam [255:0] IDENT={32'h1234,32'h5678,32'h9abc,64'd1,64'h1234567900001234,32'h0350};
    always @(posedge cap_clk) if(!cap_rst && sof && enable) begin
        if(!time_valid || age_cycles>40) $fatal(1,"FAIL: context allowed unknown/stale source time");
        captured_meta[frame_id]=frame_meta;
    end
    always @(posedge clk) if(!rst) begin
        if(commit_valid) begin
            if(commit_meta!==captured_meta[commit_meta[95:64]]) $fatal(1,"FAIL: coherent snapshot changed through FIFO/DDR descriptor");
            commits=commits+1;
        end
        if(out_valid && out_ready) begin
            if(!checking || out_event!==IDENT || out_meta!==captured_meta[pixels/4+4] || out_data!==16'hf405 ||
                out_sof!==(pixels%4==0) || out_last!==(pixels%4==3)) $fatal(1,"FAIL: context reset leaked old frame/identity");
            pixels=pixels+1;
        end
        if(result_valid && result_ready) begin
            if(!checking || result_event!==IDENT || !result_ok || result_frames!=2) $fatal(1,"FAIL: context result epoch");
            results=results+1;
        end
    end
    task frame;
        input integer id;
        begin
            @(negedge cap_clk);sof=1;frame_id=id;
            for(yy=0;yy<8;yy=yy+1) for(xx=0;xx<8;xx=xx+1) begin
                de=1;x=xx;y=yy;
                @(negedge cap_clk);sof=0;
            end
            de=0;repeat(15) @(negedge cap_clk);
        end
    endtask
    task enqueue;
        input [255:0] ident;
        begin
            @(negedge control_clk);event_data=ident;event_valid=1;
            @(posedge control_clk);while(!event_ready) @(posedge control_clk);
            @(negedge control_clk);event_valid=0;event_data=~ident;
        end
    endtask
    initial begin
        repeat(6) @(negedge control_clk);arst=0;
        wait(!control_rst && !cap_rst && !rst);
        // No coherent time yet: first SOF is rejected before snapshot delivery.
        frame(0);wait(time_valid);
        frame(1);wait(frames_committed==1);
        @(negedge control_clk);control_running=0;
        wait(age_cycles>40);frame(2);
        repeat(20) @(negedge clk);
        if(frames_committed!=1 || rejected_unknown!=1 || rejected_stale!=1) $fatal(1,"FAIL: stale/unknown frame was committed");
        control_running=1;wait(age_cycles==0);
        // Hold the B response after accepting a new frame, plus an in-flight
        // event. Cancel all three domains AND slave as one reset epoch.
        hold_b=1;frame(3);wait(memory.responding);
        enqueue(256'hbad);wait(client.ui_valid || client.evidence.dispatcher.active);
        #3;arst=1;#17;arst=0;hold_b=0;
        wait(!control_rst && !cap_rst && !rst);wait(time_valid);
        repeat(20) @(negedge clk);
        if(frames_committed || accepted_count || result_valid || out_valid || client.evidence.pipeline.slot_valid)
            $fatal(1,"FAIL: context reset retained in-flight B/window/metadata");
        frame(4);wait(frames_committed==1);
        enqueue(IDENT);wait(client.evidence.dispatcher.active);
        frame(5);wait(out_valid);
        checking=1;allow_output=1;
        wait(results==1);repeat(8) @(negedge clk);
        if(PACKET_SINK) begin
            wait(results_sent==1);repeat(4) @(negedge clk);
            if(packet_fault || packets_sent!=5) $fatal(1,"FAIL: context packet consumer identity/frames");
        end
        if(pixels!=8 || frames_committed!=2 || frames_failed || read_errors || rejected_count ||
            accepted_count!=1 || cdc_delivered_count!=1 || completed_count!=1)
            $fatal(1,"FAIL: context post-reset conservation");
        $display("PASS: evidence_capture_context time-qualified DDR frames, stale-clock rejection, in-flight B/event common reset, new UID window8pixels packet_sink=%0d packets=%0d",PACKET_SINK,packets_sent);$finish;
    end
    initial begin #2000000;$fatal(1,"FAIL: context integration timeout commits=%d age=%d",frames_committed,age_cycles);end
endmodule
