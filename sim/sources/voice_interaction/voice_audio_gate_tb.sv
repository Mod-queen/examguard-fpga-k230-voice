`timescale 1ns/1ps
module voice_audio_gate_tb;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,tick_1ms=0;
    reg [2:0] req_valid=0,bus_req_ready=0;
    wire [2:0] req_ready,bus_req_valid;
    reg [23:0] req_type=24'hffffff,req_id=24'h234440;
    // All owners deliberately have cookie 1, round 1, tag 9.
    reg [95:0] req_cookie={32'd1,32'd1,32'd1},req_round={32'd1,32'd1,32'd1};
    reg [191:0] req_tag={64'd9,64'd9,64'd9};
    reg [47:0] req_guard_ms={16'd2,16'd3,16'd4};
    wire [23:0] bus_req_type,bus_req_id;
    wire [95:0] bus_req_cookie,bus_req_round;
    wire [191:0] bus_req_tag;
    reg done_valid=0,done_ready=0;
    reg [1:0] done_owner=0;
    reg [31:0] done_cookie=1,done_round=1;
    reg [63:0] done_tag=9;
    wire audio_reserved,samples_allowed;
    voice_audio_gate dut(.*);
    task step;begin @(posedge clk);#1;end endtask
    task tick;
        input integer n;
        repeat(n) begin @(negedge clk);tick_1ms=1;step;@(negedge clk);tick_1ms=0;step;end
    endtask
    task accept;
        input [2:0] mask;
        begin
            #1;if(bus_req_valid!==mask || req_ready!==0) $fatal(1,"arbitration changed");
            @(negedge clk);bus_req_ready=7;#1;
            if(req_ready!==mask) $fatal(1,"ready routed wrong");step;
            @(negedge clk);bus_req_ready=0;req_valid=req_valid & ~mask;
            #1;if(!audio_reserved || samples_allowed || bus_req_valid) $fatal(1,"accepted write not reserved");
        end
    endtask
    task complete;
        input [1:0] owner;
        begin
            @(negedge clk);done_valid=1;done_ready=1;done_owner=owner;
            step;@(negedge clk);done_valid=0;done_ready=0;step;
        end
    endtask
    initial begin
        repeat(3) step;@(negedge clk);rst=0;step;
        if(!samples_allowed || audio_reserved) $fatal(1,"idle reserved");
        // 1: Hold all three sources, interactive owners ahead of notice owner.
        @(negedge clk);req_valid=7;step;
        if(bus_req_type!==req_type || bus_req_id!==req_id || bus_req_cookie!==req_cookie ||
           bus_req_round!==req_round || bus_req_tag!==req_tag) $fatal(1,"payload changed");
        accept(1);
        $display("scenario 1: priority, payload and handshake");

        // 2: Wrong owner/cookie/binding or unconsumed completion cannot unlock.
        complete(1);tick(5);if(!audio_reserved) $fatal(1,"owner collision");
        done_cookie=2;complete(0);tick(5);if(!audio_reserved) $fatal(1,"cookie collision");
        done_cookie=1;done_round=2;complete(0);if(!audio_reserved) $fatal(1,"round collision");
        done_round=1;done_tag=10;complete(0);if(!audio_reserved) $fatal(1,"tag collision");
        done_tag=9;@(negedge clk);done_valid=1;done_ready=0;tick(6);
        if(!audio_reserved) $fatal(1,"unconsumed completion");
        @(negedge clk);done_valid=0;
        $display("scenario 2: exact consumed completion required");

        // 3: Guard starts AFTER write completion; full configured ticks elapse.
        complete(0);tick(3);
        if(!audio_reserved || samples_allowed || bus_req_valid) $fatal(1,"guard ended early");
        tick(1);#1;
        if(audio_reserved || !samples_allowed || bus_req_valid!==2) $fatal(1,"guard did not release");
        accept(2);
        $display("scenario 3: post-write guard, polls filtered until release");

        // 4: Mutating new requests cannot retag accepted work or its timing.
        req_guard_ms=0;req_cookie=0;req_round=0;req_tag=0;
        complete(1);tick(2);if(!audio_reserved) $fatal(1,"guard was not latched");
        tick(1);if(audio_reserved || bus_req_valid!==4) $fatal(1,"second guard release");
        $display("scenario 4: in-flight labels/guard latched");

        // 5: Zero guard only releases after consumed bus completion.
        accept(4);tick(4);if(!audio_reserved) $fatal(1,"zero guard skipped transaction");
        done_cookie=0;done_round=0;done_tag=0;complete(2);
        if(audio_reserved || !samples_allowed) $fatal(1,"zero guard stuck");
        $display("scenario 5: zero guard retains transaction ownership");

        // 6: Reset cancels reservation; does not claim a hardware clip stopped.
        req_valid=1;req_guard_ms=48'h00000000ffff;step;accept(1);
        @(negedge clk);rst=1;step;
        if(bus_req_valid || samples_allowed) $fatal(1,"reset interface active");
        @(negedge clk);rst=0;step;
        if(audio_reserved || !samples_allowed) $fatal(1,"reset did not clear");
        $display("scenario 6: common reset");

        // 7: 16-bit maximum guard does not wrap on load or first tick.
        req_valid=1;step;accept(1);complete(0);tick(1);
        if(!audio_reserved || dut.remaining_ms!==16'hfffe) $fatal(1,"maximum guard wrapped");
        $display("PASS: voice_audio_gate scenarios=7");$finish;
    end
    initial begin #100000;$fatal(1,"test timeout");end
endmodule
