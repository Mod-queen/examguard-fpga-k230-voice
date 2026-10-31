`timescale 1ns/1ps
module guard_case #(parameter FP=37)(output reg passed=0);
    localparam IW=FP<2 ? 1 : $clog2(FP);
    reg clk=0, rst=1, enable=1, frame_start=0, frame_end=0;
    reg in_valid=0, in_last=0;
    reg [IW-1:0] in_index=0;
    reg [15:0] in_data=0;
    reg [95:0] in_meta=0;
    wire out_valid, out_sof, out_last;
    wire [15:0] out_data;
    wire [95:0] out_meta;
    reg out_ready=0;
    wire [1:0] banks_occupied;
    wire [31:0] frames_seen, frames_buffered, frames_sent;
    wire [31:0] dropped_busy, dropped_invalid, dropped_disabled;
    camera_frame_guard #(.FRAME_PIXELS(FP)) dut (.*);
    always #5 clk=~clk;
    integer expected [0:1023];
    integer head=0, tail=0, pixel=0, p, n, before_drop, base_sent;
    reg randomized=0;
    reg [31:0] rng=32'hface5eed;
    reg stalled=0;
    reg [113:0] previous;
    function [15:0] pattern;
        input integer f, i;
        begin pattern=(f*103)^i; end
    endfunction
    always @(negedge clk) if(randomized) begin
        rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]}; out_ready<=rng[0];
    end
    always @(posedge clk) begin
        if(rst) stalled<=0;
        else begin
            if(banks_occupied>2) $fatal(1,"FAIL: banks overbooked");
            if(stalled && (!out_valid || {out_meta,out_data,out_sof,out_last}!==previous))
                $fatal(1,"FAIL: guard output changed while stalled");
            stalled<=out_valid && !out_ready;
            previous<={out_meta,out_data,out_sof,out_last};
            if(out_valid && out_ready) begin
                if(head==tail || out_data!==pattern(expected[head],pixel) ||
                    out_meta!=={32'(expected[head]),64'(expected[head]*17)} ||
                    out_sof!==(pixel==0) || out_last!==(pixel==FP-1))
                    $fatal(1,"FAIL: guard data/order/meta FP=%d frame=%d pixel=%d",FP,head,pixel);
                if(out_last) begin head=head+1; pixel=0; end else pixel=pixel+1;
            end
        end
    end
    task expect_frame;
        input integer f;
        begin expected[tail]=f; tail=tail+1; end
    endtask
    task start_frame;
        input integer f;
        begin
            @(negedge clk); frame_start=1; in_meta={32'(f),64'(f*17)};
            if(randomized && tail-head<2) expect_frame(f);
            @(negedge clk); frame_start=0;
        end
    endtask
    task samples;
        input integer f, length, last_on;
        begin
            for(p=0;p<length;p=p+1) begin
                @(negedge clk); in_valid=1; in_index=p; in_data=pattern(f,p);
                in_last=last_on && p==length-1;
            end
            @(negedge clk); in_valid=0; in_last=0;
        end
    endtask
    task send_good;
        input integer f;
        begin start_frame(f); samples(f,FP,1); end
    endtask
    initial begin
        repeat(5) @(negedge clk); rst=0;
        // Never expose an incomplete frame.
        expect_frame(1); start_frame(1);
        if(FP>1) begin
            samples(1,FP-1,0);
            repeat(8) begin @(negedge clk); if(out_valid) $fatal(1,"FAIL: partial publication"); end
            in_valid=1; in_index=FP-1; in_data=pattern(1,FP-1); in_last=1;
            @(negedge clk); in_valid=0; in_last=0;
        end else samples(1,FP,1);
        expect_frame(2); send_good(2);
        if(banks_occupied!=2) $fatal(1,"FAIL: reserve both banks");
        send_good(3); // full at START => all of frame 3 discarded
        if(dropped_busy!=1) $fatal(1,"FAIL: full frame drop");
        // Freeing a bank midway does not admit the tail of a dropped frame.
        start_frame(4); out_ready=1; samples(4,FP,1);
        wait(head==tail); repeat(5) @(negedge clk);
        if(dropped_busy!=2 || frames_sent!=2) $fatal(1,"FAIL: late capacity must not accept tail");
        out_ready=0;
        // Early LAST, missing LAST, discontinuous index, explicit empty end.
        if(FP>1) begin start_frame(5); samples(5,FP-1,1); end
        start_frame(6); samples(6,FP,0);
        start_frame(7); @(negedge clk); in_valid=1; in_index=1; in_last=0;
        @(negedge clk); in_valid=0;
        start_frame(8); @(negedge clk); frame_end=1;
        @(negedge clk); frame_end=0;
        // Next START aborts previous short capture; both failures count.
        start_frame(9);
        start_frame(10); @(negedge clk); frame_end=1;
        @(negedge clk); frame_end=0;
        if(dropped_invalid!=(FP>1 ? 6 : 5)) $fatal(1,"FAIL: malformed accounting FP=%d got=%d",FP,dropped_invalid);
        enable=0; send_good(11); enable=1;
        if(dropped_disabled!=1) $fatal(1,"FAIL: disabled frame count");
        // START and first sample may coincide; enable change MID-frame ignored.
        expect_frame(12);
        @(negedge clk); frame_start=1; in_valid=1; in_index=0;
        in_meta={32'd12,64'd204}; in_data=pattern(12,0); in_last=FP==1;
        @(negedge clk); frame_start=0; in_valid=0; in_last=0; enable=0;
        for(p=1;p<FP;p=p+1) begin
            @(negedge clk); in_valid=1; in_index=p; in_data=pattern(12,p); in_last=p==FP-1;
        end
        @(negedge clk); in_valid=0; in_last=0; enable=1; out_ready=1;
        wait(head==tail); repeat(4) @(negedge clk);
        // Random continuous producer. Independent acceptance oracle: number of
        // known completed frames not yet delivered at START (no input ready).
        randomized=1;
        for(n=20;n<220;n=n+1) begin
            send_good(n);
        end
        randomized=0; out_ready=1; wait(head==tail); repeat(5) @(negedge clk);
        if(frames_buffered!=frames_sent || frames_buffered!=tail)
            $fatal(1,"FAIL: buffer/delivery accounting");
        // Reset discards a published stalled frame AND a partial capture.
        out_ready=0; send_good(300); start_frame(301);
        @(negedge clk); rst=1; head=0; tail=0; pixel=0;
        repeat(4) @(negedge clk); rst=0; out_ready=1;
        repeat(8) begin @(negedge clk); if(out_valid) $fatal(1,"FAIL: stale after reset"); end
        expect_frame(302); send_good(302); wait(head==tail); repeat(3) @(negedge clk);
        if(frames_sent!=1 || frames_seen!=1 || dropped_invalid!=0) $fatal(1,"FAIL: reset counters");
        $display("guard FP=%d final delivered=%d PASS",FP,frames_sent);
        passed=1;
    end
endmodule
module camera_frame_guard_tb;
    wire a,b;
    guard_case #(.FP(37)) normal(a);
    guard_case #(.FP(1)) single_pixel(b);
    initial begin wait(a&&b); $display("PASS: camera_frame_guard all checks"); $finish; end
    initial begin #3000000; $fatal(1,"FAIL: camera guard timeout"); end
endmodule
