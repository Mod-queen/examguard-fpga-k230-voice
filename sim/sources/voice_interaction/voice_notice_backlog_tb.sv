`timescale 1ns/1ps
// Real notice queue + audio guard, accelerated milliseconds. No fake ready
// bypass: every successful write reserves its complete configured play window.
module voice_notice_backlog_tb;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,tick_1ms=0,tick_1s=0,status_valid=0;
    reg [2:0] stage_id=0;
    reg [6:0] event_pulses=0;
    wire req_valid,req_ready;
    wire [7:0] req_type,req_id;
    wire [31:0] req_cookie,req_round;
    wire [63:0] req_tag;
    wire [6:0] pending_events;
    wire audio_reserved,samples_allowed;
    wire [2:0] bus_valid,gate_ready;
    wire [23:0] bus_id,bus_type;
    wire [95:0] bus_cookie,bus_round;
    wire [191:0] bus_tag;
    reg done=0;
    reg [31:0] done_cookie=0,done_round=0;
    reg [63:0] done_tag=0;
    wire [31:0] expired_count,coalesced_count;
    integer accepted_count=0,now_ms=0,second_div=0,i;
    reg [7:0] spoken[0:31];
    integer spoken_ms[0:31];
    wire [15:0] play_guard=req_id==8'h23 ? 8000 : 4000;
    voice_notice_queue notices(.clk(clk),.rst(rst),.tick_1s(tick_1s),
        .round_id(32'd1),.info_tag(64'd1),.status_valid(status_valid),.stage_id(stage_id),
        .submitted_by_timeout(1'b0),.event_pulses(event_pulses),.dispatch_enable(!audio_reserved),
        .req_valid(req_valid),.req_ready(req_ready),.req_type(req_type),.req_id(req_id),
        .req_cookie(req_cookie),.req_round(req_round),.req_tag(req_tag),
        .done_valid(done),.done_cookie(done_cookie),.done_round(done_round),.done_tag(done_tag),
        .done_error(2'b0),.pending_events(pending_events),.coalesced_count(coalesced_count),
        .expired_count(expired_count),.cancelled_count(),.failed_count(),.exhausted());
    assign req_ready=gate_ready[2];
    voice_audio_gate gate(.clk(clk),.rst(rst),.tick_1ms(tick_1ms),
        .req_valid({req_valid,2'b0}),.req_ready(gate_ready),
        .req_type({req_type,16'b0}),.req_id({req_id,16'b0}),
        .req_cookie({req_cookie,64'b0}),.req_round({req_round,64'b0}),.req_tag({req_tag,128'b0}),
        .req_guard_ms({play_guard,32'b0}),.bus_req_valid(bus_valid),.bus_req_ready(3'b111),
        .bus_req_type(bus_type),.bus_req_id(bus_id),.bus_req_cookie(bus_cookie),
        .bus_req_round(bus_round),.bus_req_tag(bus_tag),
        .done_valid(done),.done_ready(1'b1),.done_owner(2'd2),.done_cookie(done_cookie),
        .done_round(done_round),.done_tag(done_tag),.audio_reserved(audio_reserved),.samples_allowed(samples_allowed));
    always @(posedge clk) begin
        if(rst) begin done<=0;accepted_count<=0;end
        else begin
            done<=bus_valid[2];
            if(bus_valid[2]) begin
                if(accepted_count>=32) $fatal(1,"unexpected unbounded speech");
                spoken[accepted_count]<=bus_id[23:16];spoken_ms[accepted_count]<=now_ms;
                accepted_count<=accepted_count+1;
                done_cookie<=bus_cookie[95:64];done_round<=bus_round[95:64];done_tag<=bus_tag[191:128];
            end
        end
    end
    task cycles;input integer n;repeat(n) begin @(posedge clk);#1;end endtask
    task reset;
        begin @(negedge clk);rst=1;status_valid=0;event_pulses=0;tick_1ms=0;tick_1s=0;
            now_ms=0;second_div=0;cycles(3);@(negedge clk);rst=0;cycles(3);
            @(negedge clk);stage_id=3;status_valid=1;cycles(20);
            if(accepted_count!=1 || spoken[0]!=8'h23) $fatal(1,"opening guide absent");
        end
    endtask
    task pulse;input [6:0] mask;
        begin @(negedge clk);event_pulses=mask;cycles(1);@(negedge clk);event_pulses=0;cycles(2);end
    endtask
    task milliseconds;input integer n;
        repeat(n) begin
            @(negedge clk);now_ms=now_ms+1;second_div=second_div+1;
            tick_1ms=1;tick_1s=second_div==1000;
            if(second_div==1000) second_div=0;
            cycles(1);@(negedge clk);tick_1ms=0;tick_1s=0;cycles(6);
        end
    endtask
    initial begin
        $dumpfile("voice_notice_backlog_tb.vcd");$dumpvars(1,voice_notice_backlog_tb);
        // A real alarm during the 8-second opening sentence survives its wait.
        reset;pulse(7'b0000100);milliseconds(8100);
        if(accepted_count!=2 || spoken[1]!=8'h32)
            $fatal(1,"opening audio swallowed phone notice: accepted=%0d expired=%0d",accepted_count,expired_count);
        $display("PASS scenario 1: alarm waits for opening audio, no expiry");
        // Five independent simultaneous types drain over 20 seconds, not 6.
        reset;pulse(7'b1111100);milliseconds(28100);
        if(accepted_count!=6 || expired_count!=0) $fatal(1,"simultaneous notices lost count=%0d expired=%0d",accepted_count,expired_count);
        if(spoken[1]!=8'h32 || spoken[2]!=8'h33 || spoken[3]!=8'h36 || spoken[4]!=8'h37 || spoken[5]!=8'h38)
            $fatal(1,"notice order/type corrupted");
        for(i=2;i<6;i=i+1) if(spoken_ms[i]-spoken_ms[i-1]<4000) $fatal(1,"audio interrupted previous clip");
        $display("PASS scenario 2: five types drain with full audio spacing");
        // A fresh same-type event while the previous clip plays is retained.
        reset;milliseconds(8100);pulse(7'b0000100);milliseconds(100);
        pulse(7'b0000100);pulse(7'b0000100);milliseconds(8100);
        if(accepted_count!=3 || spoken[1]!=8'h32 || spoken[2]!=8'h32)
            $fatal(1,"fresh repeat swallowed by old cooldown count=%0d",accepted_count);
        if(coalesced_count!=1 || expired_count!=0) $fatal(1,"bounded repeat coalescing incorrect");
        $display("PASS scenario 3: repeated episode retained, queued duplicates coalesced");
        // Ending the exam still cancels unspoken exam alarms.
        reset;pulse(7'b1111100);milliseconds(100);
        @(negedge clk);stage_id=4;cycles(8);milliseconds(8100);
        if(accepted_count!=2 || spoken[1]!=8'h24 || pending_events!=0) $fatal(1,"old exam speech escaped stage boundary");
        $display("PASS scenario 4: stage cancellation preserved");
        $display("PASS: voice_notice_backlog scenarios=4");$finish;
    end
    initial begin #10000000;$fatal(1,"timeout");end
endmodule
