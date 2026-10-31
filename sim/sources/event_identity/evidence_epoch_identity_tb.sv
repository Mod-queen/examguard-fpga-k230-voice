`timescale 1ns/1ps
module evidence_epoch_identity_tb;
    reg clk=0,system_rst=1,transport_rst=1,ms_tick=1,session_start=0,session_end=0;
    always #10 clk=~clk;
    wire [31:0] device_id,boot_id,session_id;
    wire [63:0] time_ms;
    wire session_active,request_rst,request_enable,boot_exhausted;
    evidence_epoch_identity #(.BOOT_MAX(7)) dut(.device_straps(32'hac750001),.*);
    reg [31:0] prior_boot;
    reg [63:0] prior_time;
    integer n;
    initial begin
        repeat(4) @(negedge clk);system_rst=0;repeat(4) @(negedge clk);transport_rst=0;
        wait(!request_rst);@(negedge clk);
        session_start=1;@(negedge clk);session_start=0;
        for(n=0;n<5;n=n+1) begin
            prior_boot=boot_id;prior_time=time_ms;
            #1;transport_rst=1;#1;if(!request_rst) $fatal(1,"FAIL: epoch identity reset gate");
            repeat(4) @(negedge clk);transport_rst=0;
            if(!request_rst) $fatal(1,"FAIL: admission released before boot");
            wait(!request_rst);@(negedge clk);
            if(boot_id!=prior_boot+1 || session_id!=1 || !session_active || time_ms<=prior_time)
                $fatal(1,"FAIL: epoch identity reuse or session/time lost");
        end
        if(boot_id!=7 || boot_exhausted) $fatal(1,"FAIL: maximum boot epoch unusable");
        // BOOT_MAX reached: another cancellation must halt, not reuse boot7.
        transport_rst=1;repeat(4) @(negedge clk);transport_rst=0;
        repeat(12) @(negedge clk);
        if(!boot_exhausted || !request_rst || request_enable || boot_id!=7)
            $fatal(1,"FAIL: exhausted boot was reused");
        session_end=1;@(negedge clk);session_end=0;
        if(session_active) $fatal(1,"FAIL: epoch session close");
        // A whole-system reset starts a NEW host/configuration epoch; locally
        // counters restart. This is explicitly NOT persistent global identity.
        system_rst=1;transport_rst=1;repeat(5) @(negedge clk);system_rst=0;
        repeat(4) @(negedge clk);transport_rst=0;wait(request_enable);@(negedge clk);
        if(boot_exhausted || session_id || session_active || boot_id!=2)
            $fatal(1,"FAIL: system reset failed to recover exhausted identity");
        $display("PASS: evidence_epoch_identity transport reset changes boot before admission / retains session and time / max epoch then exhaustion halts");$finish;
    end
    initial begin #100000;$fatal(1,"FAIL: epoch identity timeout");end
endmodule
