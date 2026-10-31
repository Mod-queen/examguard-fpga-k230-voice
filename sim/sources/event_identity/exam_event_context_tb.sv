`timescale 1ns/1ps
module exam_event_context_tb;
    reg clk=0,rst=1;
    always #10 clk=~clk;
    reg tick=0,face=0,face_ok=1,start=0,submit=0,ack=0,timeout=0;
    reg object_pulse=0,gaze=0,away=0,present=1,frame=0;
    reg [2:0] object_class=7;
    reg [7:0] activity=20,luma=120;
    reg [15:0] cells=0;
    wire [2:0] stage;
    wire [1:0] risk,auth;
    wire [7:0] code;
    wire [15:0] seqno,remaining;
    wire [3:0] request;
    wire [63:0] lanes;
    exam_fsm #(.SELFCHECK_TICKS(1),.EXAM_LEN_S(3),.GAZE_TURN_FRAMES(1),.LOW_ACT_FRAMES(1),.PARALLEL_EVENTS(1)) fsm(
        .clk(clk),.rst(rst),.tick_1s(tick),.frame_pulse(frame),.face_pulse(face),.face_ok(face_ok),.face_id(2'd1),
        .object_pulse(object_pulse),.object_class(object_class),.activity_global(activity),.active_cells(cells),.luma_avg(luma),
        .gaze_pulse(gaze),.gaze_away(away),.gaze_present(present),.start_pulse(start),.submit_pulse(submit),.ack_pulse(ack),
        .timeout_pulse(timeout),.stage_id(stage),.risk_level(risk),.event_code(code),.event_seq(seqno),.remaining_s(remaining),
        .authorized_id(auth),.new_event(),.debug_luma(),.debug_base(),.debug_flags(),.debug_gaze_cnt(),
        .event_request(request),.event_request_data(lanes));
    wire session_start,session_end,session_active;
    wire [31:0] device_id,boot_id,session_id,started_count,ignored_start_count;
    wire [63:0] time_ms;
    // Tick EVERY clock, so stamping the admission edge instead of FSM edge is
    // guaranteed to fail; also test carry across the low 32-bit timestamp.
    event_identity identity(.clk(clk),.rst(rst),.ms_tick(1'b1),.device_straps(32'hac750001),.boot_pulse(1'b0),
        .session_start(session_start),.session_end(session_end),.device_id(device_id),.boot_id(boot_id),.session_id(session_id),
        .time_ms(time_ms),.session_active(session_active),.boot_event(),.session_event(),.started_count(started_count),.ignored_start_count(ignored_start_count));
    wire [3:0] aligned_request,accepted,rejected;
    wire [63:0] aligned_data,aligned_time_ms;
    wire [31:0] aligned_device,aligned_boot,aligned_session;
    exam_event_context context_inst(.clk(clk),.rst(rst),.stage(stage),.request(request),.request_data(lanes),
        .device_id(device_id),.boot_id(boot_id),.session_id(session_id),.session_active(session_active),.time_ms(time_ms),
        .session_start(session_start),.session_end(session_end),.aligned_request(aligned_request),.aligned_data(aligned_data),
        .aligned_time_ms(aligned_time_ms),.aligned_device(aligned_device),.aligned_boot(aligned_boot),.aligned_session(aligned_session));
    wire event_valid,id_exhausted;
    reg event_ready=0;
    wire [255:0] event_data;
    wire [3:0] occupancy,high_water;
    wire [31:0] accepted_count,rejected_count,delivered_count;
    event_transaction_queue #(.DEPTH(8)) queue(.clk(clk),.rst(rst),.request(aligned_request),.request_data(aligned_data),
        .device_id(aligned_device),.boot_id(aligned_boot),.session_id(aligned_session),.request_time_ms(aligned_time_ms),
        .accepted(accepted),.rejected(rejected),.event_valid(event_valid),.event_ready(event_ready),.event_data(event_data),
        .occupancy(occupancy),.high_water(high_water),.accepted_count(accepted_count),.rejected_count(rejected_count),
        .delivered_count(delivered_count),.id_exhausted(id_exhausted));
    reg [63:0] edge_time;
    integer consumed=0;
    task consume;
        input integer source,uid,sess,st,ev;
        input [63:0] stamp;
        begin
            wait(event_valid);@(negedge clk);
            if(event_data!=={32'hac750001,32'd1,32'(sess),64'(uid),stamp,8'(source),8'd0,1'b0,3'(st),2'd1,
                (ev==8'h50 || ev==8'h51 ? 2'd3 : ev==8'h60 ? 2'd2 : ev==8'h64 || ev==8'h31 || ev==8'h65 ? 2'd1 : 2'd0),8'(ev)})
                $fatal(1,"FAIL: local FSM identity/time source=%0d uid=%0d session=%0d got=%h stamp=%h",source,uid,sess,event_data,stamp);
            event_ready=1;@(negedge clk);event_ready=0;consumed=consumed+1;
        end
    endtask
    task enter_exam;
        begin
            tick=1;@(negedge clk);tick=0;
            face=1;edge_time=time_ms;@(negedge clk);face=0;
            consume(0,1,0,2,1,edge_time);
            start=1;@(negedge clk);start=0;
            if(request || stage!=3) $fatal(1,"FAIL: S3 unexpectedly emitted event");
        end
    endtask
    reg [63:0] auth_time,collision_time;
    initial begin
        repeat(4) @(negedge clk);rst=0;
        @(negedge clk);identity.time_ms=64'h12345678fffffffc;
        // Unauthorized S3 must not start a session or fabricate success.
        tick=1;@(negedge clk);tick=0;start=1;auth_time=time_ms;
        @(negedge clk);start=0;repeat(3) @(negedge clk);
        if(session_id || session_active || started_count) $fatal(1,"FAIL: unauthorized S3 session");
        // Lane auth for rejected start is 0, check separately from consume task.
        if(!event_valid || event_data[191:160]!=0 || event_data[95:32]!==auth_time || event_data[7:0]!=8'h10)
            $fatal(1,"FAIL: rejected S3 time/context");
        event_ready=1;@(negedge clk);event_ready=0;
        face=1;auth_time=time_ms;@(negedge clk);face=0;
        consume(0,2,0,2,1,auth_time);
        start=1;@(negedge clk);start=0;
        if(stage!=3 || request) $fatal(1,"FAIL: actual S3 transition");
        // Next immediate edge: session identity is being allocated concurrently
        // with new requests. Must become session1, NOT old0 or next2.
        object_pulse=1;object_class=1;gaze=1;away=1;frame=1;cells=2000;submit=1;
        collision_time=time_ms;
        @(negedge clk);object_pulse=0;gaze=0;frame=0;submit=0;
        if(request!=15 || code!=8'h21 || stage!=4 || seqno!=3) $fatal(1,"FAIL: four-source panel priority");
        repeat(8) @(negedge clk);
        if(session_id!=1 || session_active || started_count!=1 || ignored_start_count || occupancy!=4)
            $fatal(1,"FAIL: local start/end accounting");
        consume(0,3,1,4,8'h21,collision_time);
        consume(1,4,1,3,8'h50,collision_time);
        consume(2,5,1,3,8'h60,collision_time);
        consume(3,6,1,3,8'h64,collision_time);
        ack=1;edge_time=time_ms;@(negedge clk);ack=0;
        consume(0,7,1,5,8'h03,edge_time);
        if(accepted_count!=7 || rejected_count || delivered_count!=7 || high_water!=4) $fatal(1,"FAIL: local FSM conservation");
        // Common reset cancels a held event and the context pipeline.
        rst=1;repeat(3) @(negedge clk);rst=0;@(negedge clk);
        enter_exam();repeat(3) @(negedge clk);
        // Continuous darkness holds64 without masking the new phone request.
        frame=1;cells=0;luma=120;@(negedge clk);frame=0;repeat(2) @(negedge clk);
        frame=1;luma=20;edge_time=time_ms;@(negedge clk);frame=0;
        consume(3,2,1,3,8'h64,edge_time);
        frame=1;object_pulse=1;object_class=1;edge_time=time_ms;
        @(negedge clk);frame=0;object_pulse=0;
        if(request!=2 || code!=8'h50) $fatal(1,"FAIL: dark hold hid phone in parallel mode");
        consume(1,3,1,3,8'h50,edge_time);
        // Timeout and new cover share the still-current session.
        frame=1;luma=120;activity=20;@(negedge clk);frame=0;repeat(2) @(negedge clk);
        frame=1;cells=2000;timeout=1;edge_time=time_ms;
        @(negedge clk);frame=0;timeout=0;
        consume(0,4,1,4,8'h31,edge_time);consume(3,5,1,3,8'h64,edge_time);
        if(session_id!=1 || session_active || started_count!=1) $fatal(1,"FAIL: timeout advanced session");
        $display("PASS: exam_event_context real FSM S3/timecarry/four-source/submit/timeout/dark-hold/reset");$finish;
    end
    initial begin #1000000;$fatal(1,"FAIL: local event context timeout");end
endmodule
