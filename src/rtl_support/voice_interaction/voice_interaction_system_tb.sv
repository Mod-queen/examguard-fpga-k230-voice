`timescale 1ns/1ps
module voice_interaction_system_tb;
    reg clk=0;always #10 clk=~clk;
    reg rst=1,tick_1ms=0,tick_1s=0;
    reg [31:0] device_id=1,boot_id=42,seat_id=1;
    reg [63:0] monotonic_ms=0;
    reg boot_ready=1,start_blocked=0,s3_pulse=0,face=0,submit=0,timeout_pulse=0;
    wire [2:0] exam_stage;
    reg [31:0] session_id=0;
    reg [2:0] prior_stage=0;
    wire [1:0] face_id;
    wire [3:0] event_request;
    wire [63:0] event_lanes;
    reg rx_valid=0;reg [7:0] rx_data=0;
    wire exam_start_pulse,byte_valid,byte_last;
    wire legacy_ack_pulse,legacy_mute_pulse;
    wire [7:0] byte_data;
    reg byte_ready=1;
    tri1 scl_i,sda_i;
    wire scl_low,sda_low,slave_low;
    assign scl_i=scl_low ? 1'b0 : 1'bz;
    assign sda_i=(sda_low || slave_low) ? 1'b0 : 1'bz;
    reg enabled=1;
    reg [7:0] word_id=0;
    wire [7:0] last_clip;
    wire [31:0] writes,reads;
    wire help_pending,interaction_fresh;
    wire candidate_display_valid;
    wire [127:0] candidate_display_text;
    wire [31:0] candidate_display_token;
    wire [31:0] displayed_token;
    reg pixel_clk=0;always #7 pixel_clk=~pixel_clk;
    reg [7:0] frame_div=0;
    reg allow_sof=0;
    always @(posedge pixel_clk) if(rst) frame_div<=0;else frame_div<=frame_div+1'b1;
    wire [192:0] pixel_snapshot;
    wire pixel_valid;
    wire [31:0] applied_token;
    cdc_stats_snapshot #(.WIDTH(193)) to_pixel(.src_clk(clk),.src_rst(rst),
        .src_stats({candidate_display_valid,candidate_display_token,seat_id,candidate_display_text}),
        .dst_clk(pixel_clk),.dst_rst(rst),.stats(pixel_snapshot),.valid(pixel_valid),.age_cycles());
    candidate_overlay overlay(.clk(pixel_clk),.rst(rst),.sof(allow_sof && frame_div==255),.snapshot_valid(pixel_valid),
        .text_codes(pixel_snapshot[127:0]),.text_token(pixel_snapshot[191:160]),.seat(pixel_snapshot[159:128]),
        .candidate_valid(pixel_snapshot[192]),.stage(exam_stage),.x(12'd64),.y(12'd88),.de(1'b1),
        .pixel_in(24'h112233),.pixel_out(),.displayed_token(applied_token));
    cdc_stats_snapshot #(.WIDTH(32)) to_host(.src_clk(pixel_clk),.src_rst(rst),.src_stats(applied_token),
        .dst_clk(clk),.dst_rst(rst),.stats(displayed_token),.valid(),.age_cycles());
    wire [31:0] help_ticket,round_id;
    wire [63:0] info_tag;
    wire [3:0] info_state,prep_state;
    wire [15:0] remaining;
    integer starts=0,records=0,bytes=0,trace,i,legacy_ack_count=0,legacy_mute_count=0;
    reg [31:0] token=1;
    reg [511:0] command;
    reg [31:0] crc;
    reg [3:0] nibble;
    voice_interaction_system #(.QUARTER_CYCLES(2),.TIMEOUT_CYCLES(100),.POLL_CYCLES(10),
        .STALE_CYCLES(5000),.PC_TIMEOUT_MS(1000000)) dut(.*);
    wonderecho_wire_model slave(.rst(rst),.scl(scl_i),.sda(sda_i),.enabled(enabled),.word_id(word_id),
        .slave_low(slave_low),.last_clip(last_clip),.writes(writes),.reads(reads));
    exam_fsm #(.SELFCHECK_TICKS(1),.ENABLE_RUNTIME_DURATION(1),.PARALLEL_EVENTS(1)) exam(
        .clk(clk),.rst(rst),.tick_1s(tick_1s),.frame_pulse(1'b0),.face_pulse(face),.face_ok(1'b1),.face_id(2'd1),
        .object_pulse(1'b0),.object_class(3'd0),.activity_global(8'd0),.active_cells(16'd0),.luma_avg(8'd100),
        .gaze_pulse(1'b0),.gaze_away(1'b0),.gaze_present(1'b0),.start_pulse(exam_start_pulse),
        .submit_pulse(submit),.ack_pulse(1'b0),.timeout_pulse(timeout_pulse),.configured_duration_s(16'd60),
        .stage_id(exam_stage),.remaining_s(remaining),.authorized_id(face_id),.event_request(event_request),
        .event_request_data(event_lanes));
    always @(posedge clk) if(!rst) begin
        tick_1ms<=1;monotonic_ms<=monotonic_ms+1;
        prior_stage<=exam_stage;
        if(exam_stage==3 && prior_stage!=3) session_id<=session_id+1;
        if(legacy_ack_pulse) legacy_ack_count=legacy_ack_count+1;
        if(legacy_mute_pulse) legacy_mute_count=legacy_mute_count+1;
        if(exam_start_pulse) starts=starts+1;
        if(byte_valid && byte_ready) begin
            $fwrite(trace,"%c",byte_data);bytes=bytes+1;
            if(byte_last) begin if(bytes!=196) $fatal(1,"VI record shape");bytes=0;records=records+1;end
        end
    end
    function [31:0] crc_byte;
        input [31:0] old;
        input [7:0] b;
        reg [31:0] c;integer k;
        begin c=old^b;for(k=0;k<8;k=k+1)c=c[0]?(c>>1)^32'hedb88320:c>>1;crc_byte=c;end
    endfunction
    task step;begin @(posedge clk);#1;end endtask
    task send_byte;
        input [7:0] b;
        begin @(negedge clk);rx_valid=1;rx_data=b;@(negedge clk);rx_valid=0;end
    endtask
    task send;
        input [7:0] op;
        input [63:0] tag;
        input [31:0] ticket;
        begin
            command={24'h564301,op,32'h00400000,token,device_id,boot_id,round_id,tag,ticket,seat_id,160'd0,32'd0};
            if(op==5) command[191:64]=128'h85868720202036303234323032323538;
            crc=32'hffffffff;
            for(i=0;i<60;i=i+1) crc=crc_byte(crc,command[511-i*8 -:8]);
            command[31:0]=~crc;token=token+1;
            send_byte("V");send_byte("C");send_byte(",");
            for(i=0;i<128;i=i+1) begin
                nibble=command[511-i*4 -:4];send_byte(nibble<10?"0"+nibble:"A"+nibble-10);
            end
            send_byte(10);repeat(5) step;
        end
    endtask
    task tick;
        begin @(negedge clk);tick_1s=1;step;@(negedge clk);tick_1s=0;repeat(3)step;end
    endtask
    task wait_info;
        input [3:0] state;
        integer n;
        begin
            n=0;while(info_state!=state && n<100000) begin step;n=n+1;end
            if(info_state!=state) $fatal(1,"info state %d expected %d",info_state,state);
        end
    endtask
    task wait_prep;
        input [3:0] state;
        integer n;
        begin
            n=0;while(prep_state!=state && n<100000) begin step;n=n+1;end
            if(prep_state!=state) $fatal(1,"prep state %d expected %d",prep_state,state);
        end
    endtask
    task answer;
        input [7:0] id;
        begin
            wait(!dut.audio_reserved);repeat(3000)step;
            @(negedge clk);word_id=id;repeat(3000)step;
            @(negedge clk);word_id=0;
        end
    endtask
    reg [31:0] old_round,old_ticket,old_reads;
    initial begin
        trace=$fopen("system_vi_trace.txt","w");
        repeat(5)step;@(negedge clk);rst=0;tick;
        @(negedge clk);face=1;step;@(negedge clk);face=0;repeat(10)step;
        if(exam_stage!=2) $fatal(1,"not face verified");
        s3_pulse=1;step;s3_pulse=0;repeat(2000)step;
        if(starts || info_state!=0) $fatal(1,"unconfigured start");
        $display("system 1: real face verified, no roster bypass");
        old_round=round_id;send(3,64'h1234,0);
        if(round_id!=old_round+1 || info_tag!=64'h1234) $fatal(1,"configuration not rebound");
        send(4,info_tag,0);send(5,info_tag,0);send(1,info_tag,0);
        repeat(50)step;
        if(info_state!=0 || displayed_token!=0) $fatal(1,"audio prompted before HDMI frame applied");
        if(dut.flags[6]) $fatal(1,"HDMI status claimed application without SOF");
        allow_sof=1;wait_info(3);
        if(!dut.flags[6]) $fatal(1,"HDMI frame application missing from VI flags");
        // Early word during audio guard must not confirm. Polls still progress.
        old_reads=reads;word_id=4;repeat(1500)step;
        if(info_state==5 || reads<=old_reads) $fatal(1,"early audio reply or poll starvation");
        word_id=0;wait_info(4);answer(4);wait_info(5);
        if(!dut.info_permit || starts) $fatal(1,"info confirmation auto-started");
        $display("system 2: VC config/presentation/heartbeat, real I2C FF40/41, guard/zero/reply");
        @(negedge clk);s3_pulse=1;step;@(negedge clk);s3_pulse=0;
        wait_prep(3);tick;tick;
        if(exam_stage!=2 || starts) $fatal(1,"preparation counted exam");
        wait_prep(4);answer(7);wait_prep(7);
        if(exam_stage!=3 || starts!=1 || remaining!=60) $fatal(1,"compact exam start");
        if(last_clip==8'h45) $fatal(1,"extra readiness feedback");
        $display("system 3: one physical S3, preparation no timer, compact start");
        answer(8);wait(help_pending);old_ticket=help_ticket;
        wait_prep(7);tick;tick;
        if(remaining!=58 || starts!=1) $fatal(1,"help paused timer");
        answer(8);if(help_ticket!=old_ticket) $fatal(1,"help duplicated");
        send(2,info_tag,old_ticket+1);if(!help_pending) $fatal(1,"wrong ticket cleared");
        send(2,info_tag,old_ticket);repeat(5)step;
        if(help_pending) $fatal(1,"exact handler not applied");
        $display("system 4: exam help, exact VC handling, timer continues");
        wait_prep(7);answer(8);wait(help_pending);wait_prep(7);
        @(negedge clk);timeout_pulse=1;step;@(negedge clk);timeout_pulse=0;
        repeat(10)step;
        if(exam_stage!=4 || remaining!=0 || !help_pending) $fatal(1,"timeout blocked/lost help");
        send(2,info_tag,help_ticket);if(help_pending) $fatal(1,"ended help cannot clear");
        $display("system 5: real exam timeout retains ticket, ended exact handler");
        // Malformed/stale commands cannot affect freshness or binding.
        old_round=round_id;send(3,64'h9999,0);
        if(round_id!=old_round) $fatal(1,"exam-ended configure accepted");
        @(negedge clk);enabled=0;repeat(6000)step;
        if(interaction_fresh || dut.voice_fresh) $fatal(1,"NACK link remained fresh");
        $display("system 6: late config rejected, voice NACK revokes fresh");
        enabled=1;repeat(4000)step;
        @(negedge clk);dut.pc_age_ms=1000000;step;
        if(interaction_fresh) $fatal(1,"PC expiry ignored");
        send(4,info_tag,0);if(!interaction_fresh) $fatal(1,"new heartbeat not accepted");
        $display("system 7: PC heartbeat expiry/recovery");
        // Legacy S1/S2 mapping remains edge/zero-rearmed; old spoken START
        // must never create a second actual exam start.
        answer(2);answer(2);answer(1);answer(3);
        if(legacy_mute_count!=2 || legacy_ack_count!=1 || starts!=1)
            $fatal(1,"legacy compatibility or voice start bypass");
        seat_id=2;step;
        if(interaction_fresh) $fatal(1,"seat changed without re-presentation");
        seat_id=1;
        tick;repeat(1000)step;
        wait(!byte_valid);repeat(10)step;$fclose(trace);
        if(records<5) $fatal(1,"VI updates missing");
        $display("PASS: voice_interaction_system scenarios=8 records=%0d writes=%0d reads=%0d",records,writes,reads);$finish;
    end
    initial begin #20000000;$fatal(1,"test timeout");end
endmodule
