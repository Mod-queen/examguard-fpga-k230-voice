`timescale 1ns/1ps
module evidence_reset_barrier_tb;
    reg arst=1;
    reg [3:0] clocks=0;
    reg [3:0] running=15;
    always #10 if(running[0]) clocks[0]=~clocks[0];
    always #7 if(running[1]) clocks[1]=~clocks[1];
    always #5 if(running[2]) clocks[2]=~clocks[2];
    always #4 if(running[3]) clocks[3]=~clocks[3];
    wire [3:0] resets;
    evidence_reset_barrier dut(.*);
    integer d;
    task stopped_reset;
        input integer stop_domain;
        begin
            @(negedge clocks[stop_domain]);running[stop_domain]=0;
            #1;arst=1;#1;
            if(resets!==15) $fatal(1,"FAIL: barrier asynchronous assertion");
            #1;arst=0;
            #250;
            if(resets!==15) $fatal(1,"FAIL: barrier released before stopped clock %0d",stop_domain);
            running[stop_domain]=1;
            wait(resets==0);
            #100;
            if(resets!==0) $fatal(1,"FAIL: barrier release deadlocked/reasserted");
        end
    endtask
    initial begin
        #81;arst=0;wait(resets==0);
        for(d=0;d<4;d=d+1) stopped_reset(d);
        // Retrigger while release is in progress; all raw chains must restart.
        #1;arst=1;#2;arst=0;#13;arst=1;#2;
        if(resets!==15) $fatal(1,"FAIL: barrier retrigger assertion");
        arst=0;wait(resets==0);
        $display("PASS: evidence_reset_barrier four independent stopped clocks / short pulse / retrigger / no feedback deadlock");$finish;
    end
    initial begin #100000;$fatal(1,"FAIL: barrier timeout");end
endmodule
