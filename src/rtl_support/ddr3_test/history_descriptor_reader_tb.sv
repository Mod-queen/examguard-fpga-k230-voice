`timescale 1ns/1ps
module history_descriptor_reader_tb;
    reg clk=0,rst=1,start_valid=0,out_ready=0;
    always #5 clk=~clk;
    reg [6:0] start_slots=0,valid_slots=0;
    reg [255:0] start_event=0;
    reg [95:0] meta[0:6];
    wire start_ready,out_valid,done,ok,protocol_fault;
    wire [2:0] query_slot,out_slot;
    wire query_valid=valid_slots[query_slot];
    wire [95:0] query_meta=meta[query_slot];
    wire [95:0] out_meta;
    wire [255:0] out_event;
    wire [31:0] out_index;
    history_descriptor_reader #(.SLOTS(7)) dut(.*);
    integer i,j,n,seed=98;
    reg [6:0] seen;
    reg [255:0] saved_event;
    reg [63:0] prior;
    reg [130:0] held;
    task automatic start(input [6:0] slots);
        begin
            @(negedge clk);start_slots=slots;start_valid=1;saved_event=start_event;
            @(posedge clk);while(!start_ready) @(posedge clk);
            @(negedge clk);start_valid=0;
        end
    endtask
    task automatic reset_reader;
        begin @(negedge clk);rst=1;repeat(3) @(negedge clk);rst=0;end
    endtask
    initial begin
        reset_reader();
        // Physical slot order intentionally differs from chronological order.
        for(i=0;i<7;i=i+1) meta[i]={32'(i+20),64'(100+((i*3)%7)*50)};
        valid_slots=127;
        for(i=1;i<50;i=i+1) begin
            start_event={128'h123456789abcdef0123456789abcdef0,64'(i),64'hfedcba9876543210};
            start(($random(seed)&127)|1);seen=0;prior=0;n=0;
            while(!done) begin
                wait(out_valid || done);
                #1;
                if(out_valid) begin
                    held={out_slot,out_meta,out_index};
                    repeat(($random(seed)&7)+1) begin
                        @(negedge clk);
                        if(!out_valid || held!=={out_slot,out_meta,out_index} || out_event!==saved_event)
                            $fatal(1,"FAIL: descriptor/context not held under backpressure");
                    end
                    if(!start_slots[out_slot] || seen[out_slot] || out_meta!==meta[out_slot] || out_index!=n || out_meta[63:0]<=prior)
                        $fatal(1,"FAIL: descriptor ordering/duplication/metadata");
                    seen[out_slot]=1;prior=out_meta[63:0];n=n+1;
                    out_ready=1;@(negedge clk);out_ready=0;
                end
            end
            if(!ok || seen!=start_slots || protocol_fault) $fatal(1,"FAIL: reader conservation");
        end
        start(0);if(!done || ok) $fatal(1,"FAIL: empty success");
        valid_slots=0;start(1);wait(done);if(ok || !protocol_fault) $fatal(1,"FAIL: invalid reference accepted");
        reset_reader();valid_slots=127;meta[1]=meta[0];
        start(3);wait(out_valid);@(negedge clk);out_ready=1;@(negedge clk);out_ready=0;
        wait(done);if(ok || !protocol_fault) $fatal(1,"FAIL: duplicate timestamps not rejected");
        reset_reader();start(127);wait(out_valid);reset_reader();repeat(30) @(negedge clk);
        if(out_valid || done) $fatal(1,"FAIL: stale descriptor after reset");
        $display("PASS: history_descriptor_reader sorted slot subsets/backpressure/context/empty-invalid-duplicate/reset");$finish;
    end
    initial begin #2000000;$fatal(1,"FAIL: descriptor reader timeout");end
endmodule
