`timescale 1ns/1ps
module event_transaction_fork_tb;
    reg clk=0,rst=1,in_valid=0,a_ready=0,b_ready=0;
    always #5 clk=~clk;
    reg [255:0] in_data=0;
    wire in_ready,a_valid,b_valid;
    wire [255:0] a_data,b_data;
    event_transaction_fork dut(.*);
    integer accepted=0,na=0,nb=0,n,seed=17;
    reg random_run=0,checking=1;
    function [255:0] record;
        input integer i;
        begin record={32'hac750001,32'hffffffff,32'h80000001,64'(i),64'h12345678ffffffff+i,32'h01003750};end
    endfunction
    always @(negedge clk) if(random_run) begin a_ready=($random(seed)&3)!=0;b_ready=($random(seed)&7)==0;end
    always @(posedge clk) if(!rst && checking) begin
        if(in_valid && in_ready) accepted=accepted+1;
        if(a_valid && a_ready) begin if(a_data!==record(na)) $fatal(1,"FAIL: fork A duplicated/reordered");na=na+1;end
        if(b_valid && b_ready) begin if(b_data!==record(nb)) $fatal(1,"FAIL: fork B duplicated/reordered");nb=nb+1;end
        if(na>accepted || nb>accepted) $fatal(1,"FAIL: fork phantom record");
    end
    initial begin
        repeat(4) @(negedge clk);rst=0;random_run=1;
        for(n=0;n<400;n=n+1) begin
            in_valid=1;in_data=record(n);@(posedge clk);while(!in_ready) @(posedge clk);
            @(negedge clk);in_valid=0;in_data=~record(n);
        end
        wait(na==400 && nb==400);@(negedge clk);random_run=0;
        checking=0;in_valid=1;in_data=256'hbad;a_ready=1;b_ready=0;
        @(negedge clk);in_valid=0;repeat(4) @(negedge clk);
        if(a_valid || !b_valid || in_ready) $fatal(1,"FAIL: fork blocked branch ownership");
        rst=1;repeat(3) @(negedge clk);rst=0;#1;
        if(a_valid || b_valid || !in_ready) $fatal(1,"FAIL: fork reset old record");
        $display("PASS: event_transaction_fork 400 ordered exactly-once deliveries per branch independent stalls/reset");$finish;
    end
    initial begin #1000000;$fatal(1,"FAIL: fork timeout");end
endmodule
