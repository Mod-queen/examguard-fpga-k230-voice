`timescale 1ns/1ps
// Real FSM -> status serializer -> actual UART pin decoder. S3 is the ONLY
// accepted start after face verification. No time reconstructed from uptime.
module status_uart_timer_tb;
    reg clk=0,rst=1,tick_1s=0,start_pulse=0,submit_pulse=0,timeout_pulse=0,face_pulse=0;
    always #5 clk=~clk;
    wire [2:0] stage;
    wire [15:0] remaining;
    wire uart_txd,uart_busy;
    exam_fsm fsm (
        .clk(clk),.rst(rst),.tick_1s(tick_1s),.frame_pulse(1'b0),.face_pulse(face_pulse),.face_ok(1'b1),.face_id(2'd1),
        .object_pulse(1'b0),.object_class(3'd0),.activity_global(8'd0),.active_cells(16'd0),.luma_avg(8'd80),
        .gaze_pulse(1'b0),.gaze_away(1'b0),.gaze_present(1'b0),.start_pulse(start_pulse),.submit_pulse(submit_pulse),
        .ack_pulse(1'b0),.timeout_pulse(timeout_pulse),.stage_id(stage),.remaining_s(remaining));
    status_uart_tx #(.ENABLE_TIMER(1),.CLK_FREQ_HZ(921600),.BAUD_RATE(115200),.STATUS_PERIOD_CYCLES(400)) tx (
        .clk(clk),.rst(rst),.status_valid(!rst),.status_frame_id(32'd42),.status_stage_id({1'b0,stage}),
        .status_risk_level(4'd0),.status_zone_id(4'd0),.status_timestamp(32'd7000),.status_event_code(8'd0),
        .status_motion_pickup(8'd0),.status_motion_operation(8'd0),.status_motion_forbidden(8'd0),
        .event_device_id(32'd1),.event_boot_id(32'd1),.event_session_id(32'd1),.event_uid(64'd0),.event_seq(8'd0),
        .health_flags(8'd0),.remaining_s(remaining),.exam_duration_s(16'd2700),.uart_txd(uart_txd),.uart_busy(uart_busy));
    integer want_stage=-1,want_remaining=-1,matched=0,lines=0,i;
    string line="",expected_line;
    reg [7:0] ch;
    integer bitnum;
    // 8 clocks/bit. Decode serialized snapshots, not live internal registers.
    initial forever begin
        @(negedge uart_txd);#120;
        for(bitnum=0;bitnum<8;bitnum=bitnum+1) begin ch[bitnum]=uart_txd;#80;end
        if(!uart_txd) $fatal(1,"FAIL: timer UART framing");
        if(ch==10) begin
            expected_line=$sformatf("ST,0000000042,%0d,0,0,0000007000,000,000,000,000,000,%05d,02700",want_stage,want_remaining);
            if(line==expected_line) begin matched=matched+1;$display("TIMER_UART %s",line);end
            lines=lines+1;line="";
        end else line={line,ch};
    end
    task tick;
        begin @(negedge clk);tick_1s=1;@(negedge clk);tick_1s=0;end
    endtask
    task expect_timer;
        input integer s,r;
        integer previous;
        begin want_stage=s;want_remaining=r;previous=matched;wait(matched>previous);end
    endtask
    task verify;
        begin @(negedge clk);face_pulse=1;@(negedge clk);face_pulse=0;end
    endtask
    task start;
        begin @(negedge clk);start_pulse=1;@(negedge clk);start_pulse=0;end
    endtask
    task reset_epoch;
        begin @(negedge clk);rst=1;repeat(8) @(negedge clk);rst=0;repeat(3) tick();end
    endtask
    initial begin
        repeat(5) @(negedge clk);rst=0;repeat(3) tick();
        start(); // no authorization, S3 must not start timer
        expect_timer(1,0);
        verify();repeat(5) tick();expect_timer(2,0);
        start();expect_timer(3,2700);tick();expect_timer(3,2699);
        repeat(59) tick();expect_timer(3,2640);
        @(negedge clk);submit_pulse=1;@(negedge clk);submit_pulse=0;
        repeat(5) tick();expect_timer(4,2640); // early submission freezes
        reset_epoch();verify();start();
        @(negedge clk);timeout_pulse=1;@(negedge clk);timeout_pulse=0;
        expect_timer(4,0);
        reset_epoch();verify();start();repeat(2700) tick();expect_timer(4,0);
        if(matched<7) $fatal(1,"FAIL: timer transition coverage");
        $display("PASS: status_uart_timer real FSM/UART all checks");$finish;
    end
    initial begin #10000000;$fatal(1,"FAIL: timer UART timeout");end
endmodule
