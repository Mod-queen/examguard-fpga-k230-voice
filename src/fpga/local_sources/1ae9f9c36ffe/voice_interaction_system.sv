`timescale 1ns/1ps
// Complete 50MHz candidate service. Does not own exam clock/timer/reset or UART.
module voice_interaction_system #(
    parameter integer QUARTER_CYCLES=125,
    parameter integer TIMEOUT_CYCLES=500000,
    parameter integer POLL_CYCLES=2500000,
    parameter integer STALE_CYCLES=25000000,
    parameter integer PC_TIMEOUT_MS=3000,
    parameter integer GUARD_SCALE=1
) (
    input wire clk,rst,tick_1ms,tick_1s,
    input wire [31:0] device_id,boot_id,session_id,seat_id,
    input wire [63:0] monotonic_ms,
    input wire boot_ready,start_blocked,s3_pulse,
    input wire [2:0] exam_stage,
    input wire [1:0] face_id,
    input wire [3:0] event_request,
    input wire [63:0] event_lanes,
    input wire rx_valid,input wire [7:0] rx_data,
    output wire exam_start_pulse,
    output reg legacy_ack_pulse,legacy_mute_pulse,
    output wire byte_valid,byte_last,output wire [7:0] byte_data,input wire byte_ready,
    input wire scl_i,sda_i,output wire scl_low,sda_low,
    output wire help_pending,output wire [31:0] help_ticket,
    output wire [3:0] info_state,prep_state,
    output reg [31:0] round_id,
    output reg [63:0] info_tag,
    output wire interaction_fresh
    ,output wire candidate_display_valid
    ,output wire [127:0] candidate_display_text
    ,output wire [31:0] candidate_display_token
    ,input wire [31:0] displayed_token
);
    reg configured,round_live,round_exhausted;
    reg [2:0] previous_stage;
    reg [31:0] pc_age_ms;
    reg [31:0] configured_seat;
    wire pc_fresh=pc_age_ms<PC_TIMEOUT_MS;
    wire voice_fresh,heartbeat,configure;
    wire [63:0] configured_tag;
    wire display_loaded;
    assign candidate_display_valid=configured && display_loaded && !round_exhausted && configured_seat==seat_id;
    wire display_applied=candidate_display_valid && displayed_token==candidate_display_token;
    wire presented,handled;
    wire [31:0] presented_round,handled_round,handled_ticket,command_token;
    wire [63:0] presented_tag,handled_tag;
    wire [7:0] command_op,command_result;
    wire info_permit,ready_recorded,help_in_exam;
    wire [31:0] help_round;
    wire [63:0] help_tag;
    assign interaction_fresh=boot_ready && voice_fresh && pc_fresh && !round_exhausted &&
        (!configured || configured_seat==seat_id);
    always @(posedge clk) begin
        if(rst) begin
            round_id<=1;info_tag<=1;configured<=0;round_live<=0;round_exhausted<=0;
            pc_age_ms<=PC_TIMEOUT_MS;previous_stage<=0;
            configured_seat<=0;
        end else begin
            previous_stage<=exam_stage;
            if(tick_1ms && pc_age_ms<PC_TIMEOUT_MS) pc_age_ms<=pc_age_ms+1'b1;
            if(heartbeat) pc_age_ms<=0;
            if(configured && interaction_fresh && exam_stage==2) round_live<=1;
            if(exam_stage==2 && previous_stage!=2) begin
                configured<=0;round_live<=0;
                if(round_id==32'hffffffff) round_exhausted<=1;
                else round_id<=round_id+1'b1;
            end
            if(configure && exam_stage==2 && !round_exhausted) begin
                if(round_id==32'hffffffff) round_exhausted<=1;
                else begin
                    round_id<=round_id+1'b1;info_tag<=configured_tag;
                    configured<=1;round_live<=0;pc_age_ms<=PC_TIMEOUT_MS;
                    configured_seat<=seat_id;
                end
            end
        end
    end
    voice_host_endpoint host_endpoint(.clk(clk),.rst(rst),.rx_valid(rx_valid),.rx_data(rx_data),
        .device_id(device_id),.boot_id(boot_id),.round_id(round_id),.seat_id(seat_id),.info_tag(info_tag),
        .exam_stage(exam_stage),.help_pending(help_pending),.help_ticket(help_ticket),
        .presented(presented),.presented_round(presented_round),.presented_tag(presented_tag),
        .handled_pulse(handled),.handled_round(handled_round),.handled_tag(handled_tag),.handled_ticket(handled_ticket),
        .command_token(command_token),.command_op(command_op),.command_result(command_result),.rejected_lines(),
        .heartbeat_pulse(heartbeat),.configure_pulse(configure),.configured_tag(configured_tag),
        .display_loaded(display_loaded),.display_text(candidate_display_text),.display_token(candidate_display_token));

    wire [2:0] req_valid,req_ready,bus_req_valid,bus_req_ready;
    wire [23:0] req_id,req_type;
    wire [95:0] req_cookie;
    wire [31:0] notice_round;
    wire [63:0] notice_tag;
    wire [95:0] req_round={notice_round,round_id,round_id};
    wire [191:0] req_tag={notice_tag,info_tag,info_tag};
    wire [23:0] bus_req_id,bus_req_type;
    wire [95:0] bus_req_cookie,bus_req_round;
    wire [191:0] bus_req_tag;
    wire done_valid;
    wire [1:0] done_owner,done_error;
    wire [31:0] done_cookie,done_round;
    wire [63:0] done_tag;
    wire raw_sample_valid,sample_eligible;
    wire [7:0] sample_id;
    wire [31:0] sample_round;
    wire [63:0] sample_tag;
    wire audio_reserved,samples_allowed;
    wire sample_valid=raw_sample_valid && sample_eligible && samples_allowed;
    reg [7:0] last_legacy_word;
    always @(posedge clk) begin
        if(rst) begin last_legacy_word<=0;legacy_ack_pulse<=0;legacy_mute_pulse<=0;end
        else begin
            legacy_ack_pulse<=0;legacy_mute_pulse<=0;
            if(raw_sample_valid && sample_eligible && samples_allowed) begin
                last_legacy_word<=sample_id;
                if(sample_id!=0 && sample_id!=last_legacy_word) begin
                    if(sample_id==1) legacy_ack_pulse<=1;
                    if(sample_id==2) legacy_mute_pulse<=1;
                end
            end
        end
    end
    wire info_done=done_valid && done_owner==0 && done_round==round_id && done_tag==info_tag;
    wire prep_done=done_valid && done_owner==1 && done_round==round_id && done_tag==info_tag;
    assign req_type[15:0]=16'hffff;
    voice_info_confirm #(.PROMPT_TIMEOUT_S(20),.REPLY_TIMEOUT_S(30)) information(
        .clk(clk),.rst(rst),.tick_1s(tick_1s),.verified(exam_stage==2 && round_live && !round_exhausted),
        .link_ok(interaction_fresh),.round_id(round_id),.info_tag(info_tag),
        .presented(presented && display_applied),.presented_round(presented_round),.presented_tag(presented_tag),
        .sample_valid(sample_valid),.sample_round(sample_round),.sample_tag(sample_tag),.sample_id(sample_id),
        .prompt_valid(req_valid[0]),.prompt_ready(req_ready[0]),.prompt_id(req_id[7:0]),.prompt_cookie(req_cookie[31:0]),
        .prompt_done(info_done),.done_cookie(done_cookie),.prompt_ok(done_error==0),
        .start_permit(info_permit),.state(info_state),.confirmed_pulse());
    voice_exam_interaction #(.READY_FEEDBACK(0),.PROMPT_TIMEOUT_S(20)) preparation(
        .clk(clk),.rst(rst),.tick_1s(tick_1s),.exam_stage(exam_stage),.info_permit(info_permit),
        .start_blocked(start_blocked || !boot_ready),.s3_pulse(s3_pulse),.link_ok(interaction_fresh),
        .round_id(round_id),.info_tag(info_tag),.sample_valid(sample_valid),.sample_round(sample_round),
        .sample_tag(sample_tag),.sample_id(sample_id),.prompt_valid(req_valid[1]),.prompt_ready(req_ready[1]),
        .prompt_id(req_id[15:8]),.prompt_cookie(req_cookie[63:32]),.prompt_done(prep_done),
        .done_cookie(done_cookie),.prompt_ok(done_error==0),.help_pending(help_pending),.help_ticket(help_ticket),
        .help_in_exam(help_in_exam),.help_round(help_round),.help_tag(help_tag),.help_handled(handled),
        .handled_round(handled_round),.handled_tag(handled_tag),.handled_ticket(handled_ticket),
        .exam_start_pulse(exam_start_pulse),.ready_recorded(ready_recorded),.state(prep_state));
    reg [6:0] event_pulses;
    reg timeout_submit;
    integer lane;
    always @* begin
        event_pulses=0;timeout_submit=0;
        for(lane=0;lane<4;lane=lane+1) if(event_request[lane]) begin
            case(event_lanes[lane*16 +:8])
                8'h10:event_pulses[0]=1;8'h11:event_pulses[1]=1;
                8'h50:event_pulses[2]=1;8'h51:event_pulses[3]=1;
                8'h60:event_pulses[4]=1;8'h64:event_pulses[5]=1;8'h65:event_pulses[6]=1;
                8'h31:timeout_submit=1;
            endcase
        end
    end
    voice_notice_queue notices(.clk(clk),.rst(rst),.tick_1s(tick_1s),.round_id(round_id),.info_tag(info_tag),
        .status_valid(boot_ready),.stage_id(exam_stage),.submitted_by_timeout(timeout_submit),.event_pulses(event_pulses),
        .dispatch_enable(!audio_reserved && !req_valid[0] && !req_valid[1]),.req_valid(req_valid[2]),.req_ready(req_ready[2]),
        .req_type(req_type[23:16]),.req_id(req_id[23:16]),.req_cookie(req_cookie[95:64]),
        .req_round(notice_round),.req_tag(notice_tag),.done_valid(done_valid && done_owner==2),
        .done_cookie(done_cookie),.done_round(done_round),.done_tag(done_tag),.done_error(done_error),
        .pending_events(),.coalesced_count(),.expired_count(),.cancelled_count(),.failed_count(),.exhausted());

    function [15:0] guard_ms;
        input [7:0] id;
        begin
            // Conservative initial budgets for the short prepared vocabulary.
            // Hardware listening must check actual generated clip lengths.
            case(id)
                8'h40:guard_ms=3500*GUARD_SCALE;
                8'h41:guard_ms=3500*GUARD_SCALE;
                8'h44:guard_ms=5000*GUARD_SCALE;
                8'h23:guard_ms=8000*GUARD_SCALE;
                default:guard_ms=4000*GUARD_SCALE;
            endcase
        end
    endfunction
    wire [47:0] guards={guard_ms(req_id[23:16]),guard_ms(req_id[15:8]),guard_ms(req_id[7:0])};
    voice_audio_gate audio(.clk(clk),.rst(rst),.tick_1ms(tick_1ms),.req_valid(req_valid),.req_ready(req_ready),
        .req_type(req_type),.req_id(req_id),.req_cookie(req_cookie),.req_round(req_round),.req_tag(req_tag),.req_guard_ms(guards),
        .bus_req_valid(bus_req_valid),.bus_req_ready(bus_req_ready),.bus_req_type(bus_req_type),.bus_req_id(bus_req_id),
        .bus_req_cookie(bus_req_cookie),.bus_req_round(bus_req_round),.bus_req_tag(bus_req_tag),
        .done_valid(done_valid),.done_ready(1'b1),.done_owner(done_owner),.done_cookie(done_cookie),
        .done_round(done_round),.done_tag(done_tag),.audio_reserved(audio_reserved),.samples_allowed(samples_allowed));
    voice_interaction_bus #(.QUARTER_CYCLES(QUARTER_CYCLES),.TIMEOUT_CYCLES(TIMEOUT_CYCLES),
        .POLL_CYCLES(POLL_CYCLES),.STALE_CYCLES(STALE_CYCLES)) bus(
        .clk(clk),.rst(rst),.round_id(round_id),.info_tag(info_tag),.poll_eligible(samples_allowed),
        .req_valid(bus_req_valid),.req_ready(bus_req_ready),.req_type(bus_req_type),.req_id(bus_req_id),
        .req_cookie(bus_req_cookie),.req_round(bus_req_round),.req_tag(bus_req_tag),
        .done_valid(done_valid),.done_ready(1'b1),.done_owner(done_owner),.done_cookie(done_cookie),
        .done_round(done_round),.done_tag(done_tag),.done_error(done_error),.sample_valid(raw_sample_valid),
        .sample_eligible(sample_eligible),.sample_id(sample_id),.sample_round(sample_round),.sample_tag(sample_tag),
        .link_fresh(voice_fresh),.busy(),.scl_i(scl_i),.sda_i(sda_i),.scl_low(scl_low),.sda_low(sda_low));

    reg [31:0] status_sequence;
    reg dirty,seq_exhausted;
    reg [2:0] previous_snapshot_stage;
    reg [3:0] previous_info,previous_prep;
    reg previous_help;
    reg [31:0] previous_round,previous_command;
    wire status_ready;
    wire can_report=boot_ready && face_id!=0 && exam_stage>=2 && !seq_exhausted &&
        (exam_stage!=3 || session_id!=0);
    wire publish=can_report && dirty && status_ready;
    wire [7:0] flags={1'b0,display_applied,help_in_exam,help_pending,ready_recorded,info_permit,
        presented && presented_round==round_id && presented_tag==info_tag,interaction_fresh};
    wire [7:0] error_code=!voice_fresh ? 8'd1 : !pc_fresh ? 8'd2 : round_exhausted ? 8'd3 : 8'd0;
    wire [735:0] payload={48'h564901000060,flags,{5'd0,exam_stage},device_id,boot_id,session_id,
        status_sequence+32'd1,round_id,info_tag,help_ticket,seat_id,monotonic_ms,{6'd0,face_id},
        {4'd0,info_state},{4'd0,prep_state},error_code,command_token,command_op,command_result,240'd0};
    always @(posedge clk) begin
        if(rst) begin
            status_sequence<=0;dirty<=1;seq_exhausted<=0;previous_snapshot_stage<=0;
            previous_info<=0;previous_prep<=0;previous_help<=0;previous_round<=0;previous_command<=0;
        end else begin
            previous_snapshot_stage<=exam_stage;previous_info<=info_state;previous_prep<=prep_state;
            previous_help<=help_pending;previous_round<=round_id;previous_command<=command_token;
            if(publish) begin
                dirty<=0;
                if(status_sequence==32'hfffffffe) seq_exhausted<=1;
                status_sequence<=status_sequence+1'b1;
            end
            if(tick_1s || exam_stage!=previous_snapshot_stage || info_state!=previous_info ||
               prep_state!=previous_prep || help_pending!=previous_help || round_id!=previous_round ||
               command_token!=previous_command) dirty<=1;
        end
    end
    voice_status_record record(.clk(clk),.rst(rst),.status_valid(publish),.status_ready(status_ready),.payload(payload),
        .byte_valid(byte_valid),.byte_last(byte_last),.byte_data(byte_data),.byte_ready(byte_ready));
endmodule
