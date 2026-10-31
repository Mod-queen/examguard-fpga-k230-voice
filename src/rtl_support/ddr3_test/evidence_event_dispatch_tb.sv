`timescale 1ns/1ps
module dispatch_case #(parameter DEPTH=3)(output reg passed=0);
    localparam CW=$clog2(DEPTH+1);
    reg clk=0,rst=1,request=0,engine_ready=0,window_started=0,window_done=0,window_ok=0,result_ready=0;
    always #5 clk=~clk;
    reg [255:0] request_data=0;
    reg [31:0] window_frames=0;
    wire accepted,rejected,engine_event,active,active_deferred,result_valid,result_deferred,result_ok;
    wire [255:0] active_event,result_event;
    wire [31:0] accepted_count,rejected_count,completed_count,result_frames;
    wire [CW-1:0] occupancy,high_water;
    evidence_event_dispatch #(.DEPTH(DEPTH)) dut(.*);
    reg [255:0] expected[0:4095];
    reg expected_deferred[0:4095];
    integer head=0,tail=0,started=0,completed=0,rejected_n=0,n=0,busy_cycles=0;
    reg [31:0] rng=32'h6578abcd;
    reg [255:0] act_expected=0;
    reg act_deferred=0, expected_ok=0;
    reg stalled=0;
    reg [289:0] held_result;
    always @(posedge clk) begin
        if(rst) begin
            head=0;tail=0;started=0;completed=0;rejected_n=0;stalled=0;
        end else begin
            if(stalled && (!result_valid || {result_event,result_deferred,result_ok,result_frames}!==held_result))
                $fatal(1,"FAIL: event result changed while stalled");
            stalled=result_valid && !result_ready;
            held_result={result_event,result_deferred,result_ok,result_frames};
            if(engine_event) begin
                if(head==tail || active || result_valid) $fatal(1,"FAIL: invalid dispatch");
                act_expected=expected[head];act_deferred=expected_deferred[head];head=head+1;started=started+1;
            end
            if(accepted) begin
                expected[tail]=request_data;
                expected_deferred[tail]=active || result_valid || occupancy!=0 || !engine_ready;
                tail=tail+1;
            end
            if(rejected) rejected_n=rejected_n+1;
            if(active && active_event!==act_expected) $fatal(1,"FAIL: active identity");
            if(result_valid && result_ready) begin
                if(result_event!==act_expected || result_deferred!==act_deferred ||
                    result_ok!==expected_ok || result_frames!==4)
                    $fatal(1,"FAIL: result payload/identity/flags");
                completed=completed+1;
            end
        end
    end
    task cycle_engine;
        begin
            window_started=0;window_done=0;
            if(active) begin
                if(busy_cycles==0) begin window_started=1;window_frames=4; end
                if(busy_cycles==5) begin window_done=1;window_ok=rng[4];expected_ok=rng[4]; end
                busy_cycles=busy_cycles+1;
            end else busy_cycles=0;
        end
    endtask
    initial begin
        repeat(5) @(negedge clk);rst=0;
        // Fill while engine unavailable; keep original identity despite input changes.
        for(n=0;n<DEPTH+2;n=n+1) begin
            request=1;request_data={32'd1,32'd2,32'd3,64'(n),64'(n*100),32'h0050};
            @(negedge clk);
        end
        request=0;
        if(occupancy!=DEPTH || rejected_count!=2) $fatal(1,"FAIL: queue full accounting");
        engine_ready=1;
        // full pop+push uses freed slot, preserving the old head.
        request=1;request_data=256'hdeadbeef;
        @(negedge clk);request=0;
        if(occupancy!=DEPTH || accepted_count!=DEPTH+1) $fatal(1,"FAIL: full simultaneous replace");
        for(n=0;n<1600;n=n+1) begin
            rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
            cycle_engine(); engine_ready=rng[2] || active;result_ready=rng[0];
            request=rng[1];request_data={32'h11223344,32'd9,32'(n/100),64'(n+100),64'(n*17),32'h0260};
            @(negedge clk);
        end
        request=0;engine_ready=1;result_ready=1;
        while(occupancy!=0 || active || result_valid) begin cycle_engine();@(negedge clk);end
        window_started=0;window_done=0;
        if(accepted_count!=tail || rejected_count!=rejected_n || completed_count!=completed || completed!=started || started!=tail)
            $fatal(1,"FAIL: dispatch conservation depth=%d",DEPTH);
        // Reset with queued data invalidates that epoch and returns no old result.
        engine_ready=0;request=1;request_data=256'hbad;
        @(negedge clk);request=0;rst=1;
        repeat(3) @(negedge clk);rst=0;engine_ready=1;
        repeat(10) @(negedge clk);
        if(occupancy || active || result_valid || accepted_count || rejected_count || completed_count)
            $fatal(1,"FAIL: stale event after reset");
        // Saturation is observable without billions of cycles; seed counters
        // at max, then exercise real admission/rejection/completion edges.
        @(negedge clk);dut.accepted_count=32'hffffffff;dut.rejected_count=32'hffffffff;dut.completed_count=32'hffffffff;
        engine_ready=0;
        for(n=0;n<DEPTH+1;n=n+1) begin request=1;request_data=n;@(negedge clk);end
        request=0;engine_ready=1;
        while(occupancy!=0 || active || result_valid) begin cycle_engine();@(negedge clk);end
        if(accepted_count!=32'hffffffff || rejected_count!=32'hffffffff || completed_count!=32'hffffffff)
            $fatal(1,"FAIL: saturated counters wrapped");
        window_started=0;window_done=0;
        $display("dispatch depth=%d randomized cycles=1600 PASS",DEPTH);passed=1;
    end
endmodule
module evidence_event_dispatch_tb;
    wire a,b;
    dispatch_case #(.DEPTH(1)) ca(a);
    dispatch_case #(.DEPTH(3)) cb(b);
    initial begin wait(a&&b);$display("PASS: evidence_event_dispatch all checks");$finish;end
    initial begin #500000;$fatal(1,"FAIL: dispatcher timeout");end
endmodule
