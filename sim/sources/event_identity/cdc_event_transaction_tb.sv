`timescale 1ns/1ps
module transaction_cdc_case #(parameter SRC_HALF=10,DST_HALF=5,WIDTH=256)(output reg passed=0);
    reg src_clk=0,dst_clk=0,src_rst=1,dst_rst=1;
    always #(SRC_HALF) src_clk=~src_clk;
    always #(DST_HALF) dst_clk=~dst_clk;
    reg src_valid=0,dst_ready=0;
    reg [WIDTH-1:0] src_data=0;
    wire src_ready,dst_valid;
    wire [WIDTH-1:0] dst_data;
    wire [31:0] src_accepted_count,dst_delivered_count;
    cdc_event_transaction #(.DATA_WIDTH(WIDTH)) dut(.*);
    reg [WIDTH-1:0] expected[0:1023];
    integer tail=0,head=0,n;
    reg [31:0] rng=32'h765abcd1;
    reg random_ready=0,stalled=0;
    reg [WIDTH-1:0] held;
    function [WIDTH-1:0] pattern;
        input integer i;
        reg [255:0] v;
        begin v={32'h1234abcd^i,32'h87654321+i,32'hfedcba98-i,64'habcdef0123450000+i,64'h3456789abcdef000+i,32'h13579bdf^i};pattern=v;end
    endfunction
    always @(posedge src_clk) if(!src_rst && src_valid && src_ready) begin expected[tail]=src_data;tail=tail+1;end
    always @(posedge dst_clk) begin
        if(dst_rst) stalled<=0;
        else begin
            if(stalled && (!dst_valid || dst_data!==held)) $fatal(1,"FAIL: event CDC held payload changed");
            stalled<=dst_valid && !dst_ready;held<=dst_data;
            if(dst_valid && dst_ready) begin
                if(head>=tail || dst_data!==expected[head]) $fatal(1,"FAIL: event CDC data/order/duplicate");
                head=head+1;
            end
        end
    end
    always @(negedge dst_clk) if(random_ready) begin
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};dst_ready=rng[0] && rng[2];
    end
    task send;
        input integer i;
        begin
            @(negedge src_clk);src_valid=1;src_data=pattern(i);
            @(posedge src_clk);while(!src_ready) @(posedge src_clk);
            @(negedge src_clk);src_valid=0;src_data=~pattern(i);
        end
    endtask
    task reset_epoch;
        begin
            // Assertion covers several clocks of BOTH domains; no independent
            // reset contract is being assumed or tested as supported.
            src_valid=0;src_rst=1;dst_rst=1;
            repeat(8) @(negedge src_clk);
            head=0;tail=0;src_rst=0;
            @(negedge dst_clk);dst_rst=0;
        end
    endtask
    initial begin
        reset_epoch();
        send(1);wait(dst_valid);
        repeat(80) @(negedge dst_clk);
        if(src_ready || src_accepted_count!=1 || dst_delivered_count!=0) $fatal(1,"FAIL: CDC acknowledged before downstream consume");
        random_ready=1;
        for(n=2;n<=301;n=n+1) begin repeat(n%3) @(negedge src_clk);send(n);end
        wait(head==tail);wait(src_ready);@(negedge src_clk);
        if(src_accepted_count!=301 || dst_delivered_count!=301) $fatal(1,"FAIL: CDC handshake counts");
        // Cancel transaction stalled at destination, then ensure no ghost.
        random_ready=0;@(negedge dst_clk);dst_ready=0;
        send(400);wait(dst_valid);reset_epoch();dst_ready=1;
        repeat(12) @(negedge dst_clk);
        if(dst_valid || dst_delivered_count || head) $fatal(1,"FAIL: CDC stale epoch leak");
        send(401);wait(head==1);wait(src_ready);
        // Maximum counters saturate on real handshakes.
        @(negedge src_clk);dut.src_accepted_count=32'hffffffff;
        @(negedge dst_clk);dut.dst_delivered_count=32'hffffffff;
        send(402);wait(head==2);wait(src_ready);
        if(src_accepted_count!=32'hffffffff || dst_delivered_count!=32'hffffffff) $fatal(1,"FAIL: CDC counters wrapped");
        $display("event CDC clocks=%0d/%0d width=%0d ordered301/stall/reset/saturation PASS",SRC_HALF*2,DST_HALF*2,WIDTH);
        passed=1;
    end
endmodule
module cdc_event_transaction_tb;
    wire a,b;
    transaction_cdc_case #(.SRC_HALF(10),.DST_HALF(5)) control_ui(a);
    transaction_cdc_case #(.SRC_HALF(3),.DST_HALF(11),.WIDTH(37)) faster_source(b);
    initial begin wait(a&&b);$display("PASS: cdc_event_transaction all checks");$finish;end
    initial begin #2000000;$fatal(1,"FAIL: event CDC timeout");end
endmodule
