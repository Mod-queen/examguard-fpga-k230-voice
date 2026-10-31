`timescale 1ns/1ps
// Actual information controller -> new controller -> delivered exam_fsm.
// Voice/PC transport remains a transaction-level fixture, not a real I2C/GUI.
module voice_exam_interaction_tb #(parameter integer READY_FEEDBACK=1);
    reg clk=0; always #10 clk=~clk;
    reg rst=1,tick_1s=0,face_pulse=0;
    reg start_blocked=0,s3_pulse=0,link_ok=1;
    reg [31:0] round_id=1;
    reg [63:0] info_tag=64'h1234;
    reg sample_valid=0;
    reg [31:0] sample_round=1;
    reg [63:0] sample_tag=64'h1234;
    reg [7:0] sample_id=0;
    reg prompt_ready=0,prompt_done=0,prompt_ok=1;
    reg [31:0] done_cookie=0;
    reg help_handled=0;
    reg [31:0] handled_round=1,handled_ticket=0;
    reg [63:0] handled_tag=64'h1234;
    wire prompt_valid,help_pending,help_in_exam,exam_start_pulse,ready_recorded;
    wire [7:0] prompt_id;
    wire [31:0] prompt_cookie,help_ticket;
    wire [31:0] help_round;
    wire [63:0] help_tag;
    wire [3:0] state;
    wire [2:0] exam_stage;
    wire [15:0] remaining_s;
    wire info_permit,ipvalid;
    wire [7:0] ipid;
    wire [31:0] ipcookie;
    wire [3:0] info_state;
    reg ipready=0,ipdone=0,ipok=1;
    reg [31:0] ipdone_cookie=0;
    reg submit=0,timeout_pulse=0;
    reg [15:0] duration=60;
    integer starts=0,scenarios=0;
    reg [31:0] previous_ticket,previous_cookie;

    voice_info_confirm #(.REPLY_TIMEOUT_S(30),.PROMPT_TIMEOUT_S(3)) info(
        .clk(clk),.rst(rst),.tick_1s(tick_1s),.verified(exam_stage==2),
        .link_ok(link_ok),.round_id(round_id),.info_tag(info_tag),
        .presented(1'b1),.presented_round(round_id),.presented_tag(info_tag),
        .sample_valid(sample_valid),.sample_round(sample_round),.sample_tag(sample_tag),.sample_id(sample_id),
        .prompt_valid(ipvalid),.prompt_ready(ipready),.prompt_id(ipid),.prompt_cookie(ipcookie),
        .prompt_done(ipdone),.done_cookie(ipdone_cookie),.prompt_ok(ipok),
        .start_permit(info_permit),.state(info_state),.confirmed_pulse());
    voice_exam_interaction #(.REPLY_TIMEOUT_S(3),.PROMPT_TIMEOUT_S(3),.READY_FEEDBACK(READY_FEEDBACK)) dut(.*);
    exam_fsm #(.SELFCHECK_TICKS(1),.ENABLE_RUNTIME_DURATION(1),.PARALLEL_EVENTS(1)) exam(
        .clk(clk),.rst(rst),.tick_1s(tick_1s),.frame_pulse(1'b0),
        .face_pulse(face_pulse),.face_ok(1'b1),.face_id(2'd1),
        .object_pulse(1'b0),.object_class(3'd0),.activity_global(8'd0),
        .active_cells(16'd0),.luma_avg(8'd100),
        .gaze_pulse(1'b0),.gaze_away(1'b0),.gaze_present(1'b0),
        .start_pulse(exam_start_pulse),.submit_pulse(submit),.ack_pulse(1'b0),
        .timeout_pulse(timeout_pulse),.configured_duration_s(duration),
        .stage_id(exam_stage),.remaining_s(remaining_s),.risk_level(),.event_code(),
        .event_seq(),.authorized_id(),.new_event(),.debug_luma(),.debug_base(),
        .debug_flags(),.debug_gaze_cnt(),.event_request(),.event_request_data());
    always @(posedge clk) begin
        if(rst) starts<=0;
        else if(exam_start_pulse) starts<=starts+1;
    end
    task step;
        begin @(posedge clk);#1;end
    endtask
    task check_state;
        input [3:0] expected;
        begin if(state!==expected) $fatal(1,"state=%0d expected=%0d",state,expected);end
    endtask
    task tick;
        begin @(negedge clk);tick_1s=1;step;@(negedge clk);tick_1s=0;end
    endtask
    task sample;
        input [7:0] id;
        begin
            @(negedge clk);sample_valid=1;sample_id=id;step;
            @(negedge clk);sample_valid=0;
        end
    endtask
    task s3;
        begin @(negedge clk);s3_pulse=1;step;@(negedge clk);s3_pulse=0;end
    endtask
    task init_round;
        begin
            @(negedge clk);rst=1;link_ok=1;start_blocked=0;tick_1s=0;
            sample_valid=0;prompt_ready=0;prompt_done=0;prompt_ok=1;
            ipready=0;ipdone=0;ipok=1;face_pulse=0;s3_pulse=0;
            help_handled=0;submit=0;timeout_pulse=0;duration=60;
            round_id=round_id+1;sample_round=round_id;sample_tag=info_tag;
            handled_round=round_id;handled_tag=info_tag;
            repeat(3) step;
            @(negedge clk);rst=0;
            tick;
            @(negedge clk);face_pulse=1;step;
            @(negedge clk);face_pulse=0;
            repeat(3) step;
            if(exam_stage!=2) $fatal(1,"not verified");
        end
    endtask
    task info_prompt;
        input [7:0] id;
        begin
            if(!ipvalid || ipid!=id) $fatal(1,"wrong info prompt");
            @(negedge clk);ipready=1;step;
            @(negedge clk);ipready=0;ipdone=1;ipdone_cookie=ipcookie;
            step;
            @(negedge clk);ipdone=0;
        end
    endtask
    task confirm_info;
        begin
            info_prompt(8'h40);sample(0);sample(4);info_prompt(8'h41);
            if(!info_permit) $fatal(1,"not confirmed");
        end
    endtask
    task finish_prompt;
        input [7:0] id;
        input ok;
        reg [31:0] cookie;
        begin
            if(id==8'h45 && !READY_FEEDBACK) begin
                if(prompt_valid || state!=5) $fatal(1,"compact flow queued extra ready speech");
            end else begin
            if(!prompt_valid || prompt_id!=id) $fatal(1,"wrong prompt %h wanted %h",prompt_id,id);
            cookie=prompt_cookie;
            repeat(3) begin
                step;
                if(!prompt_valid || prompt_cookie!=cookie || prompt_id!=id)
                    $fatal(1,"request changed under backpressure");
            end
            @(negedge clk);prompt_ready=1;step;check_state(2);
            @(negedge clk);prompt_ready=0;prompt_done=1;done_cookie=cookie;prompt_ok=ok;
            step;
            @(negedge clk);prompt_done=0;
            end
        end
    endtask
    task prep;
        begin init_round;confirm_info;s3;finish_prompt(8'h44,1);sample(0);check_state(4);end
    endtask
    task begin_exam;
        begin
            prep;sample(7);finish_prompt(8'h45,1);
            repeat(3) step;
            if(exam_stage!=3 || starts!=1 || remaining_s!=60) $fatal(1,"start failed");
            sample(0);check_state(7);
        end
    endtask
    task handle_help;
        input [31:0] ticket;
        begin
            @(negedge clk);help_handled=1;handled_ticket=ticket;
            step;
            @(negedge clk);help_handled=0;
        end
    endtask

    initial begin
        init_round;
        s3;sample(7);repeat(3) step;
        if(starts!=0 || state!=0 || exam_stage!=2) $fatal(1,"unconfirmed S3 admitted");
        scenarios=scenarios+1;

        confirm_info;sample(7);repeat(3) step;
        if(starts!=0 || state!=0) $fatal(1,"ready without S3 admitted");
        scenarios=scenarios+1;

        prep;
        s3;check_state(4); // duplicate S3 does not ask again
        tick;tick;
        if(exam_stage!=2 || starts!=0) $fatal(1,"prep consumed exam time");
        sample(7);finish_prompt(8'h45,1);repeat(3) step;
        if(exam_stage!=3 || remaining_s!=60 || starts!=1 || !ready_recorded) $fatal(1,"normal start");
        duration=7200;sample(7);s3;tick;
        if(remaining_s!=59 || starts!=1) $fatal(1,"duplicate start or duration changed");
        scenarios=scenarios+1;

        prep;sample(8);previous_ticket=help_ticket;
        if(!help_pending || help_in_exam || help_round!=round_id || help_tag!=info_tag)
            $fatal(1,"prep help missing or misbound");
        finish_prompt(8'h46,1);sample(0);sample(8);sample(7);
        repeat(4) tick;
        if(help_ticket!=previous_ticket || starts!=0 || state!=4) $fatal(1,"help duplicated/ready bypass");
        handled_round=round_id-1;handle_help(previous_ticket);
        if(!help_pending) $fatal(1,"old PC round cleared help");
        handled_round=round_id;handle_help(previous_ticket-1);
        if(!help_pending) $fatal(1,"wrong PC ticket cleared help");
        handle_help(previous_ticket);
        sample(7);check_state(3); // teacher ack requires a new neutral/readiness
        sample(0);sample(7);finish_prompt(8'h45,1);repeat(3) step;
        if(starts!=1 || exam_stage!=3) $fatal(1,"handled prep help did not resume");
        scenarios=scenarios+1;

        begin_exam;sample(8);previous_ticket=help_ticket;
        if(!help_pending || !help_in_exam) $fatal(1,"exam help missing");
        finish_prompt(8'h47,1);sample(0);sample(8);sample(8);
        tick;tick;
        if(remaining_s!=58 || starts!=1 || help_ticket!=previous_ticket) $fatal(1,"help paused/duplicated");
        handle_help(previous_ticket);sample(8);
        if(help_pending) $fatal(1,"stale help after handled");
        sample(0);sample(8);
        if(!help_pending || help_ticket!=previous_ticket+1) $fatal(1,"new help not rearmed");
        scenarios=scenarios+1;

        prep;tick;tick;tick;finish_prompt(8'h48,1);check_state(9);
        sample(7);if(starts!=0) $fatal(1,"late ready after timeout");
        s3;finish_prompt(8'h44,1);sample(0);sample(7);finish_prompt(8'h45,1);
        repeat(3) step;if(starts!=1) $fatal(1,"explicit timeout retry failed");
        scenarios=scenarios+1;

        prep;sample_round=round_id-1;sample(7);check_state(4);
        sample_round=round_id;sample_tag=info_tag+1;sample(7);check_state(4);
        sample_tag=info_tag;sample(6);finish_prompt(8'h44,1);
        sample(7);check_state(3);sample(0);check_state(4);
        scenarios=scenarios+1;

        init_round;confirm_info;start_blocked=1;s3;check_state(0);
        start_blocked=0;s3;finish_prompt(8'h44,1);sample(0);sample(7);
        start_blocked=1;finish_prompt(8'h45,1);repeat(4) step;
        if(starts!=0 || exam_start_pulse) $fatal(1,"maintenance bypassed");
        start_blocked=0;repeat(3) step;
        if(starts!=1) $fatal(1,"maintenance release not applied");
        scenarios=scenarios+1;

        if(READY_FEEDBACK) begin prep;sample(7);finish_prompt(8'h45,0);end
        else begin init_round;confirm_info;s3;finish_prompt(8'h44,0);end
        check_state(10);
        if(starts!=0) $fatal(1,"failed feedback started exam");
        scenarios=scenarios+1;

        init_round;confirm_info;s3;previous_cookie=prompt_cookie;
        @(negedge clk);prompt_ready=1;step;
        @(negedge clk);prompt_ready=0;prompt_done=1;done_cookie=previous_cookie-1;
        step;check_state(2);
        @(negedge clk);prompt_done=0;
        tick;tick;tick;check_state(10);
        if(starts!=0) $fatal(1,"stale completion started exam");
        scenarios=scenarios+1;

        prep;
        @(negedge clk);info_tag=info_tag+1;sample_valid=1;sample_id=7;
        step;check_state(0);
        @(negedge clk);sample_valid=0;
        if(starts!=0 || exam_start_pulse) $fatal(1,"revised info admitted");
        scenarios=scenarios+1;

        begin_exam;sample(8);finish_prompt(8'h47,1);
        @(negedge clk);link_ok=0;step;check_state(10);
        tick;
        if(remaining_s!=59 || !help_pending || starts!=1) $fatal(1,"link loss paused exam/lost help");
        @(negedge clk);link_ok=1;step;check_state(10);
        scenarios=scenarios+1;

        begin_exam;sample(8);finish_prompt(8'h47,1);
        @(negedge clk);submit=1;step;
        @(negedge clk);submit=0;step;check_state(11);
        sample(8);sample(7);s3;
        if(exam_stage!=4 || starts!=1 || !help_pending) $fatal(1,"post-submit action/lost ticket");
        handle_help(help_ticket);if(help_pending) $fatal(1,"ended ticket cannot be handled");
        scenarios=scenarios+1;

        init_round;confirm_info;s3;
        sample(7);check_state(1);
        finish_prompt(8'h44,1);sample(7);check_state(3);
        sample(0);check_state(4);
        tick;tick;
        @(negedge clk);tick_1s=1;sample_valid=1;sample_id=7;
        step;
        if(prompt_id!=8'h48 || starts!=0) $fatal(1,"ready won deadline");
        @(negedge clk);tick_1s=0;sample_valid=0;
        finish_prompt(8'h48,1);check_state(9);
        scenarios=scenarios+1;

        prep;
        @(negedge clk);link_ok=0;step;check_state(10);
        @(negedge clk);link_ok=1;
        sample(7);s3;check_state(10);
        if(starts!=0) $fatal(1,"reconnected prep silently resumed");
        scenarios=scenarios+1;

        begin_exam;sample(8);finish_prompt(8'h47,1);
        @(negedge clk);timeout_pulse=1;step;
        @(negedge clk);timeout_pulse=0;step;check_state(11);
        if(exam_stage!=4 || remaining_s!=0 || !help_pending || starts!=1)
            $fatal(1,"exam timeout blocked by interaction");
        scenarios=scenarios+1;

        prep;
        @(negedge clk);force dut.cookie_counter=32'hffffffff;
        sample(6);check_state(10);
        @(negedge clk);release dut.cookie_counter;
        if(prompt_valid || starts!=0) $fatal(1,"prompt cookie wrapped");
        scenarios=scenarios+1;

        prep;
        @(negedge clk);force dut.help_ticket=32'hffffffff;
        sample(8);check_state(10);
        @(negedge clk);release dut.help_ticket;
        if(help_pending || exam_start_pulse) $fatal(1,"ticket wrapped");
        @(negedge clk);rst=1;step;
        if(help_pending || exam_start_pulse || ready_recorded || prompt_valid) $fatal(1,"reset outputs");
        scenarios=scenarios+1;

        $display("PASS: voice_exam_interaction scenarios=%0d",scenarios);$finish;
    end
    initial begin #500000;$fatal(1,"test timeout");end
endmodule
