`timescale 1ns/1ps

// Self-checking testbench for the ExamGuard voice_announcer.
module voice_announcer_tb;

    localparam [2:0] S_IDLE      = 3'd0;
    localparam [2:0] S_WAIT      = 3'd1;
    localparam [2:0] S_VERIFIED  = 3'd2;
    localparam [2:0] S_EXAM      = 3'd3;
    localparam [2:0] S_SUBMITTED = 3'd4;
    localparam [2:0] S_END       = 3'd5;

    reg        clk;
    reg        rst;
    reg        valid;
    reg  [2:0] stage_id;
    reg  [7:0] event_code;
    reg  [7:0] event_seq;
    wire       tts_req;
    wire [7:0] tts_type;
    wire [7:0] tts_id;

    integer    errors;
    integer    count;
    reg  [7:0] cap_type;
    reg  [7:0] cap_id;
    reg        test_done;

    voice_announcer dut (
        .clk        (clk),
        .rst        (rst),
        .valid      (valid),
        .stage_id   (stage_id),
        .event_code (event_code),
        .event_seq  (event_seq),
        .tts_req    (tts_req),
        .tts_type   (tts_type),
        .tts_id     (tts_id)
    );

    always @(posedge clk) begin
        if (tts_req) begin
            count    = count + 1;
            cap_type = tts_type;
            cap_id   = tts_id;
        end
    end

    always #5 clk = ~clk;

    task run_cycles;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1)
                @(posedge clk);
        end
    endtask

    task pulse;
        input [2:0] st;
        input [7:0] code;
        input [7:0] seq;
        begin
            stage_id   = st;
            event_code = code;
            event_seq  = seq;
            valid      = 1'b1;
            run_cycles(1);
            valid      = 1'b0;
            run_cycles(2);
        end
    endtask

    task check;
        input            cond;
        input [8*40-1:0] name;
        begin
            if (cond)
                $display("  ok   : %0s", name);
            else begin
                $display("  FAIL : %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        clk        = 1'b0;
        rst        = 1'b1;
        valid      = 1'b0;
        stage_id   = S_IDLE;
        event_code = 8'h00;
        event_seq  = 8'h00;
        errors     = 0;
        count      = 0;
        cap_type   = 8'h00;
        cap_id     = 8'h00;
        test_done  = 1'b0;

        run_cycles(4);
        rst = 1'b0;
        run_cycles(2);

        // First snapshot: S_IDLE guide prompt.
        pulse(S_IDLE, 8'h00, 8'd0);
        check(count === 1 && cap_type === 8'hFF && cap_id === 8'h20,
              "S_IDLE -> guide 0x20");

        // Same stage repeated must not re-announce.
        pulse(S_IDLE, 8'h00, 8'd0);
        check(count === 1, "same stage suppressed");

        // S_WAIT guide prompt.
        pulse(S_WAIT, 8'h00, 8'd0);
        check(count === 2 && cap_id === 8'h21, "S_WAIT -> guide 0x21");

        // 0x11 auth failure without a stage change.
        pulse(S_WAIT, 8'h11, 8'd1);
        check(count === 3 && cap_id === 8'h31, "0x11 -> announcement 0x31");
        pulse(S_WAIT, 8'h11, 8'd1);
        check(count === 3, "same episode suppressed");

        // 0x50 phone.
        pulse(S_WAIT, 8'h50, 8'd2);
        check(count === 4 && cap_id === 8'h32, "0x50 -> announcement 0x32");

        // S_VERIFIED co-timed with 0x01: stage guide wins, event not repeated.
        pulse(S_VERIFIED, 8'h01, 8'd3);
        check(count === 5 && cap_id === 8'h22, "S_VERIFIED -> guide 0x22");

        // S_EXAM guide (S3 start).
        pulse(S_EXAM, 8'h00, 8'd3);
        check(count === 6 && cap_id === 8'h23, "S_EXAM -> guide 0x23");

        // 0x64 camera blocked during the exam.
        pulse(S_EXAM, 8'h64, 8'd4);
        check(count === 7 && cap_id === 8'h37, "0x64 -> announcement 0x37");

        // Timeout drives S_SUBMITTED: the timeout prompt, not the normal one.
        pulse(S_SUBMITTED, 8'h31, 8'd5);
        check(count === 8 && cap_id === 8'h26, "S_SUBMITTED+0x31 -> 0x26");

        // S_END guide.
        pulse(S_END, 8'h03, 8'd6);
        check(count === 9 && cap_id === 8'h25, "S_END -> guide 0x25");

        // Unmapped event is silent but consumes the sequence.
        pulse(S_END, 8'h02, 8'd7);
        check(count === 9, "unmapped 0x02 silent");

        // Zero code without a stage change is ignored.
        pulse(S_END, 8'h00, 8'd8);
        check(count === 9, "zero code ignored");

        if (errors == 0)
            $display("PASS: voice_announcer");
        else
            $display("FAIL: voice_announcer (%0d errors)", errors);
        test_done = 1'b1;
        $finish;
    end

    initial begin
        #200000;
        if (!test_done)
            $display("FAIL: voice_announcer timeout");
        $finish;
    end

endmodule
