`timescale 1ns/1ps
module cdc_time_snapshot_tb;
    reg src_clk=0,dst_clk=0,src_rst=1,dst_rst=1;
    reg src_running=1;
    always #10 if(src_running) src_clk=~src_clk;
    always #7 dst_clk=~dst_clk;
    reg [63:0] src_time_ms=64'h12345678fffffff0;
    wire [63:0] time_ms;
    wire time_valid;
    wire [31:0] age_cycles;
    cdc_time_snapshot dut(.*);
    reg [63:0] expected[0:2047];
    integer tail=0,head=0,updates=0;
    reg [63:0] last=0,stale_time;
    reg [31:0] old_age;
    always @(posedge src_clk) begin
        if(!src_rst) begin
            src_time_ms<=src_time_ms+1;
            if(dut.bridge.src_ready) begin expected[tail]=src_time_ms;tail=tail+1;end
        end
    end
    always @(posedge dst_clk) if(!dst_rst && dut.transferred) begin
        if(head>=tail || dut.transferred_time!==expected[head]) $fatal(1,"FAIL: torn timestamp snapshot/rollover");
        head=head+1;updates=updates+1;
    end
    always @(negedge dst_clk) if(!dst_rst && time_valid) begin
        if(time_ms<last) $fatal(1,"FAIL: coherent time moved backwards");
        last=time_ms;
    end
    task reset_epoch;
        begin
            src_rst=1;dst_rst=1;
            repeat(8) @(negedge src_clk);
            head=0;tail=0;updates=0;last=0;
            src_time_ms=64'h12345678fffffff0;src_rst=0;
            @(negedge dst_clk);dst_rst=0;
        end
    endtask
    initial begin
        reset_epoch();
        if(time_valid || age_cycles) $fatal(1,"FAIL: uninitialized time shown as valid");
        wait(updates==80);repeat(2) @(negedge src_clk);src_running=0;
        // Allow final source handshake to finish downstream. No PC/local
        // increment after source clock stops: retain value and grow age only.
        repeat(20) @(negedge dst_clk);stale_time=time_ms;old_age=age_cycles;
        repeat(100) @(negedge dst_clk);
        if(time_ms!==stale_time || age_cycles!=old_age+100) $fatal(1,"FAIL: stopped clock time fabricated/not aged");
        dut.age_cycles=32'hffffffff;
        repeat(3) @(negedge dst_clk);
        if(age_cycles!=32'hffffffff) $fatal(1,"FAIL: timestamp age wrapped");
        src_running=1;wait(time_ms>stale_time);
        reset_epoch();wait(time_valid);
        if(time_ms<64'h12345678fffffff0 || time_ms>src_time_ms) $fatal(1,"FAIL: stale timestamp after joint reset");
        $display("PASS: cdc_time_snapshot coherent rollover/stopped-clock age/reset all checks");$finish;
    end
    initial begin #1000000;$fatal(1,"FAIL: coherent time timeout");end
endmodule
