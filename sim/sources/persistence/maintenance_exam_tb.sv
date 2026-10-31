`timescale 1ns/1ps
// Modified independent candidate FSM: duration latches at S3, maintenance blocks S3.
module maintenance_exam_tb;
    reg clk=0,rst=1;always #10 clk=~clk;
    reg tick=0,face=0,start=0,submit=0,timeout=0,busy=0;
    reg [15:0] duration=60;wire [2:0] stage;wire [15:0] remaining;
    exam_fsm #(.ENABLE_RUNTIME_DURATION(1),.SELFCHECK_TICKS(1)) dut(
        .clk(clk),.rst(rst),.tick_1s(tick),.frame_pulse(1'b0),.face_pulse(face),.face_ok(1'b1),.face_id(2'd1),
        .object_pulse(1'b0),.object_class(3'd0),.activity_global(8'd0),.active_cells(16'd0),.luma_avg(8'd100),
        .gaze_pulse(1'b0),.gaze_away(1'b0),.gaze_present(1'b0),.start_pulse(start && !busy),
        .submit_pulse(submit),.ack_pulse(1'b0),.timeout_pulse(timeout),.configured_duration_s(duration),
        .stage_id(stage),.risk_level(),.event_code(),.event_seq(),.remaining_s(remaining),.authorized_id(),
        .new_event(),.debug_luma(),.debug_base(),.debug_flags(),.debug_gaze_cnt(),.event_request(),.event_request_data());
    task automatic pulse_tick;
        begin @(negedge clk);tick=1;@(negedge clk);tick=0;end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;pulse_tick();pulse_tick();
        @(negedge clk);face=1;@(negedge clk);face=0;
        if(stage!=2) $fatal(1,"FAIL: auth did not reach verified");
        busy=1;start=1;repeat(3) @(negedge clk);start=0;
        if(stage!=2) $fatal(1,"FAIL: maintenance start gate");
        busy=0;start=1;@(negedge clk);start=0;
        if(stage!=3 || remaining!=60) $fatal(1,"FAIL: duration not applied");
        duration=7200;pulse_tick();#1;
        if(remaining!=59) $fatal(1,"FAIL: mid-exam duration changed clock");
        @(negedge clk);timeout=1;@(negedge clk);timeout=0;
        if(stage!=4 || remaining!=0) $fatal(1,"FAIL: timeout path");
        $display("PASS: maintenance_exam runtime60/start-maintenance-gate/in-exam-duration-locked/forced-timeout");$finish;
    end
    initial begin #100000;$fatal(1,"FAIL: maintenance exam timeout");end
endmodule
