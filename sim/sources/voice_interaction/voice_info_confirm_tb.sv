`timescale 1ns/1ps
module voice_info_confirm_tb;
    reg clk=0;
    always #10 clk=~clk;
    reg rst=1, tick_1s=0, verified=0, link_ok=1, presented=0;
    reg [31:0] round_id=1, presented_round=1, sample_round=1;
    reg [63:0] info_tag=64'h1234, presented_tag=64'h1234, sample_tag=64'h1234;
    reg sample_valid=0;
    reg [7:0] sample_id=0;
    reg prompt_ready=0, prompt_done=0, prompt_ok=1;
    reg [31:0] done_cookie=0;
    wire prompt_valid, start_permit, confirmed_pulse;
    wire [7:0] prompt_id;
    wire [31:0] prompt_cookie;
    wire [3:0] state;
    integer confirmations=0;
    integer scenarios=0;
    reg [31:0] old_cookie;
    voice_info_confirm #(.REPLY_TIMEOUT_S(3),.PROMPT_TIMEOUT_S(2)) dut(.*);
    always @(posedge clk) if (!rst && confirmed_pulse) confirmations=confirmations+1;

    task step;
        begin @(posedge clk); #1; end
    endtask
    task expect_state;
        input [3:0] expected;
        begin
            if (state !== expected) $fatal(1,"state=%0d expected=%0d",state,expected);
        end
    endtask
    task fresh_round;
        begin
            @(negedge clk);
            round_id=round_id+1;
            presented_round=round_id;
            sample_round=round_id;
            presented_tag=info_tag;
            sample_tag=info_tag;
            presented=1; verified=1; link_ok=1;
            tick_1s=0; sample_valid=0; prompt_ready=0; prompt_done=0;
            step; expect_state(0);
            step; expect_state(1);
        end
    endtask
    task finish_prompt;
        input [7:0] expected_id;
        input success;
        reg [31:0] cookie;
        begin
            if (!prompt_valid || prompt_id !== expected_id) $fatal(1,"wrong prompt");
            cookie=prompt_cookie;
            repeat(4) begin
                step;
                if (!prompt_valid || prompt_id !== expected_id || prompt_cookie !== cookie)
                    $fatal(1,"unstable held request");
            end
            @(negedge clk); prompt_ready=1;
            step; expect_state(2);
            @(negedge clk); prompt_ready=0; prompt_done=1;
            done_cookie=cookie; prompt_ok=success;
            step;
            @(negedge clk); prompt_done=0;
        end
    endtask
    task sample;
        input [7:0] id;
        begin
            @(negedge clk); sample_valid=1; sample_id=id;
            step;
            @(negedge clk); sample_valid=0;
        end
    endtask
    task tick;
        begin
            @(negedge clk); tick_1s=1;
            step;
            @(negedge clk); tick_1s=0;
        end
    endtask
    task ready_for_reply;
        begin
            fresh_round;
            finish_prompt(8'h40,1);
            expect_state(3);
            sample(0); expect_state(4);
        end
    endtask

    initial begin
        repeat(3) step;
        @(negedge clk); rst=0;
        sample(4); expect_state(0);
        if(start_permit) $fatal(1,"reply before verification");
        scenarios=scenarios+1;

        @(negedge clk); verified=1;
        repeat(4) step;
        expect_state(0);
        @(negedge clk); presented=1; presented_tag=64'h9999;
        repeat(4) step;
        expect_state(0); // Presentation of another record is insufficient.
        scenarios=scenarios+1;

        fresh_round;
        sample(4); expect_state(1); // Reply before prompt completion is ignored.
        finish_prompt(8'h40,1);
        sample(4); expect_state(3); // Old nonzero register cannot confirm.
        sample(0); expect_state(4);
        sample(1); expect_state(4); // Legacy S1 word is never information consent.
        sample(3); expect_state(4); // Legacy start word cannot provide consent.
        sample(99); expect_state(4);
        if(start_permit) $fatal(1,"unknown word admitted");
        sample(4); expect_state(1);
        if(start_permit) $fatal(1,"admitted before feedback write completed");
        finish_prompt(8'h41,1); expect_state(5);
        if(!start_permit) $fatal(1,"confirmation not admitted");
        sample(4); expect_state(5);
        repeat(3) step;
        if(confirmations != 1) $fatal(1,"duplicate confirmation");
        scenarios=scenarios+1;

        // Permission disappears immediately on information change, before clock.
        @(negedge clk); info_tag=64'h5678;
        #1; if(start_permit) $fatal(1,"stale info permit");
        step; expect_state(0);
        repeat(3) step; expect_state(0); // old presentation cannot restart
        scenarios=scenarios+1;

        ready_for_reply;
        sample_round=round_id-1; sample(4); expect_state(4);
        sample_round=round_id;
        sample_tag=info_tag-1; sample(4); expect_state(4);
        sample_tag=info_tag;
        sample(5); expect_state(1);
        finish_prompt(8'h42,1); expect_state(6);
        sample(4); expect_state(6);
        if(start_permit) $fatal(1,"denial admitted");
        scenarios=scenarios+1;

        ready_for_reply;
        sample(6); expect_state(1);
        finish_prompt(8'h40,1); expect_state(3);
        sample(4); expect_state(3);
        sample(0); sample(4);
        finish_prompt(8'h41,1); expect_state(5);
        scenarios=scenarios+1;

        ready_for_reply;
        tick; sample(99); tick; tick;
        expect_state(1); finish_prompt(8'h43,1); expect_state(7);
        sample(4); repeat(8) step; expect_state(7);
        scenarios=scenarios+1;

        ready_for_reply;
        tick; tick;
        @(negedge clk); tick_1s=1; sample_valid=1; sample_id=4;
        step; expect_state(1);
        if(prompt_id != 8'h43) $fatal(1,"deadline did not win");
        @(negedge clk); tick_1s=0; sample_valid=0;
        scenarios=scenarios+1;

        fresh_round;
        old_cookie=prompt_cookie;
        finish_prompt(8'h40,0); expect_state(8);
        sample(0); sample(4); expect_state(8);
        scenarios=scenarios+1;

        fresh_round;
        @(negedge clk); prompt_ready=1;
        step;
        @(negedge clk); prompt_ready=0; prompt_done=1;
        done_cookie=old_cookie; prompt_ok=1;
        step; expect_state(2);
        @(negedge clk); prompt_done=0;
        tick; tick; expect_state(8);
        scenarios=scenarios+1;

        fresh_round; tick; tick; expect_state(8); // send not accepted
        scenarios=scenarios+1;

        ready_for_reply;
        @(negedge clk); link_ok=0;
        step; expect_state(8);
        @(negedge clk); link_ok=1;
        sample(4); expect_state(8);
        scenarios=scenarios+1;

        ready_for_reply; sample(4); finish_prompt(8'h41,1);
        @(negedge clk); presented=0;
        #1; if(start_permit) $fatal(1,"presentation loss admitted");
        step; expect_state(8);
        scenarios=scenarios+1;

        ready_for_reply; sample(4); finish_prompt(8'h41,1);
        @(negedge clk); verified=0;
        #1; if(start_permit) $fatal(1,"stage exit admitted");
        step; expect_state(0);
        scenarios=scenarios+1;

        ready_for_reply;
        // A same-edge rebind wins over a valid reply from the old round.
        @(negedge clk); round_id=round_id+1; sample_valid=1; sample_id=4;
        step; expect_state(0);
        if(start_permit) $fatal(1,"round transition admitted old reply");
        @(negedge clk); sample_valid=0;
        scenarios=scenarios+1;

        ready_for_reply; sample(4); finish_prompt(8'h41,1);
        @(negedge clk); link_ok=0;
        #1; if(start_permit) $fatal(1,"lost link retained permission");
        step; expect_state(8);
        @(negedge clk); link_ok=1;
        step; expect_state(8);
        scenarios=scenarios+1;

        // Inject exhaustion, then ensure another request cannot wrap its cookie.
        ready_for_reply;
        @(negedge clk); force dut.cookie_counter=32'hffffffff;
        sample(6); expect_state(8);
        @(negedge clk); release dut.cookie_counter;
        if(start_permit || prompt_valid) $fatal(1,"cookie exhaustion admitted");
        scenarios=scenarios+1;

        @(negedge clk); rst=1;
        step; expect_state(0);
        if(start_permit || prompt_valid) $fatal(1,"reset outputs");
        scenarios=scenarios+1;
        $display("PASS: voice_info_confirm scenarios=%0d",scenarios);
        $finish;
    end
    initial begin #200000; $fatal(1,"test timeout"); end
endmodule
