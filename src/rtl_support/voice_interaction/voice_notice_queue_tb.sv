`timescale 1ns/1ps
module voice_notice_queue_tb;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,tick_1s=0,status_valid=0,submitted_by_timeout=0;
    reg [31:0] round_id=1;
    reg [63:0] info_tag=64'h123456789abcdef0;
    reg [2:0] stage_id=0;
    reg [6:0] event_pulses=0;
    reg dispatch_enable=0,req_ready=0,done_valid=0;
    reg [31:0] done_cookie=0,done_round=0;
    reg [63:0] done_tag=0;
    reg [1:0] done_error=0;
    wire req_valid,exhausted;
    wire [7:0] req_type,req_id;
    wire [31:0] req_cookie,req_round,coalesced_count,expired_count,cancelled_count,failed_count;
    wire [63:0] req_tag;
    wire [6:0] pending_events;
    voice_notice_queue #(.NOTICE_TTL_S(3),.REPEAT_COOLDOWN_S(5)) dut(.*);
    task cycles;
        input integer n;
        repeat(n) begin @(posedge clk);#1;end
    endtask
    task reset;
        begin
            @(negedge clk);rst=1;dispatch_enable=0;req_ready=0;done_valid=0;
            status_valid=0;event_pulses=0;tick_1s=0;
            cycles(3);@(negedge clk);rst=0;cycles(2);
        end
    endtask
    task snapshot;
        input [2:0] stage;
        input timeout_submit;
        begin
            @(negedge clk);status_valid=1;stage_id=stage;submitted_by_timeout=timeout_submit;
            cycles(1);@(negedge clk);status_valid=0;cycles(1);
        end
    endtask
    task pulses;
        input [6:0] events;
        begin @(negedge clk);event_pulses=events;cycles(1);@(negedge clk);event_pulses=0;cycles(1);end
    endtask
    task tick;
        input integer n;
        repeat(n) begin
            @(negedge clk);tick_1s=1;cycles(1);@(negedge clk);tick_1s=0;cycles(1);
        end
    endtask
    task accept;
        input [7:0] expected;
        integer wait_cycles;
        reg [167:0] held;
        begin
            @(negedge clk);dispatch_enable=1;
            wait_cycles=0;
            while(!req_valid && wait_cycles<20) begin cycles(1);wait_cycles=wait_cycles+1;end
            if(!req_valid || req_id!==expected || req_type!==8'hff)
                $fatal(1,"request expected=%h actual=%h valid=%b",expected,req_id,req_valid);
            held={req_id,req_cookie,req_round,req_tag};
            cycles(4);
            if(!req_valid || {req_id,req_cookie,req_round,req_tag}!==held)
                $fatal(1,"backpressure changed request");
            @(negedge clk);req_ready=1;cycles(1);
            @(negedge clk);req_ready=0;dispatch_enable=0;cycles(1);
            if(req_valid) $fatal(1,"accepted request repeated");
        end
    endtask
    task complete;
        input [1:0] error_code;
        begin
            @(negedge clk);done_cookie=req_cookie;done_round=req_round;done_tag=req_tag;
            done_error=error_code;done_valid=1;cycles(1);
            @(negedge clk);done_valid=0;cycles(1);
        end
    endtask
    task quiet;
        begin
            @(negedge clk);dispatch_enable=1;cycles(8);
            if(req_valid) $fatal(1,"unexpected speech %h",req_id);
            @(negedge clk);dispatch_enable=0;
        end
    endtask
    reg [31:0] old_cookie,old_round;
    reg [63:0] old_tag;
    integer j;
    initial begin
        // 1: Boot chatter optional; verified stage delegated to FF40 owner.
        reset;snapshot(0,0);quiet;snapshot(1,0);accept(8'h21);complete(0);
        snapshot(2,0);quiet;
        $display("scenario 1: selftest/duplicate verification suppressed");

        // 2: A blocked old stage is replaced by the newest stage, not replayed.
        reset;snapshot(1,0);snapshot(2,0);snapshot(3,0);accept(8'h23);complete(0);quiet;
        $display("scenario 2: latest stage wins");

        // 3: Independent same-cycle alarms all survive, repeated pulses coalesce.
        pulses(7'b1111100);pulses(7'b1111100);
        if(coalesced_count!==5) $fatal(1,"coalescing count");
        accept(8'h32);complete(0);accept(8'h33);complete(0);
        accept(8'h36);complete(0);accept(8'h37);complete(0);accept(8'h38);complete(0);quiet;
        $display("scenario 3: five simultaneous alarm types survive");

        // 4: Same alarm cooldown affects voice only, then permits a fresh pulse.
        pulses(7'b0000100);quiet;
        if(coalesced_count!==6) $fatal(1,"cooldown count");
        tick(5);pulses(7'b0000100);accept(8'h32);complete(0);
        $display("scenario 4: per-type cooldown and rearm");

        // 5: Queued speech expires; repeated pulses never extend old notice TTL.
        reset;snapshot(3,0);accept(8'h23);complete(0);
        pulses(7'b0001100);tick(2);pulses(7'b0001100);tick(1);quiet;
        if(expired_count!==2 || pending_events!==0) $fatal(1,"pending expiry");
        $display("scenario 5: stale backlog expires without replay");

        // 6: Offered but unaccepted alarm also expires, no bus side effect.
        pulses(7'b0010000);@(negedge clk);dispatch_enable=1;cycles(3);
        if(!req_valid || req_id!==8'h36) $fatal(1,"missing offered alarm");
        tick(3);quiet;
        if(expired_count!==3 || cancelled_count!==1) $fatal(1,"offered expiry");
        $display("scenario 6: stalled offer expiry");

        // 7: New stage cancels an unaccepted alarm; timeout picks FF26, not FF24.
        reset;snapshot(3,0);accept(8'h23);complete(0);pulses(7'b0000100);
        @(negedge clk);dispatch_enable=1;cycles(3);
        snapshot(4,1);
        if(req_valid && req_id==8'h32) $fatal(1,"old alarm leaked after submit");
        accept(8'h26);complete(0);snapshot(5,0);accept(8'h25);complete(0);quiet;
        if(cancelled_count!==1) $fatal(1,"stage cancellation");
        $display("scenario 7: phase cancellation and timeout wording");

        // 8: Inflight old-round transaction drains. Wrong identities cannot free it.
        reset;snapshot(1,0);accept(8'h21);
        old_cookie=req_cookie;old_round=req_round;old_tag=req_tag;
        @(negedge clk);round_id=2;info_tag=64'h2222;cycles(3);snapshot(3,0);
        @(negedge clk);done_valid=1;done_cookie=old_cookie+1;done_round=old_round;done_tag=old_tag;
        dispatch_enable=1;cycles(2);if(req_valid) $fatal(1,"wrong cookie released inflight");
        @(negedge clk);done_cookie=old_cookie;done_round=round_id;done_tag=info_tag;
        cycles(2);if(req_valid) $fatal(1,"wrong context released inflight");
        @(negedge clk);done_valid=0;dispatch_enable=0;complete(1);
        accept(8'h23);
        if(req_cookie<=old_cookie || req_round!==2 || req_tag!==64'h2222 || failed_count!==1)
            $fatal(1,"old labels or failure counter");
        complete(0);quiet;
        $display("scenario 8: exact completion, old round drain, no failed-write retry");

        // 9: Scope gates, normal submit, nonwrapping cookie exhaustion/reset.
        reset;snapshot(1,0);accept(8'h21);complete(0);
        pulses(7'b1111111);accept(8'h30);complete(0);accept(8'h31);complete(0);quiet;
        snapshot(4,0);accept(8'h24);complete(0);
        @(negedge clk);dut.cookie_counter=32'hffffffff;
        snapshot(5,0);@(negedge clk);dispatch_enable=1;cycles(4);
        if(!exhausted || req_valid) $fatal(1,"cookie wrapped");
        reset;snapshot(1,0);accept(8'h21);complete(0);
        $display("PASS: voice_notice_queue scenarios=9");$finish;
    end
    initial begin #100000;$fatal(1,"test timeout");end
endmodule
