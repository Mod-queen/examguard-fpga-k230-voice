`timescale 1ns/1ps
module axi_read_burst_buffer_tb;
    reg clk=0,rst=1,ar_fire=0,in_last=0,in_valid=0,out_ready=0;
    always #5 clk=~clk;
    reg [127:0] in_data=0;
    reg [3:0] in_id=0;
    reg [1:0] in_resp=0;
    wire ar_open,in_ready,out_last,out_valid,overflow_fault;
    wire [127:0] out_data;
    wire [3:0] out_id;
    wire [1:0] out_resp;
    axi_read_burst_buffer dut(.*);
    integer n,p,got=0;
    reg checking=1;
    always @(posedge clk) if(!rst && out_valid && out_ready) begin
        if(checking && (out_data!==128'(got+1000) || out_id!==4'(got%16) || out_resp!==2'(got%4) || out_last!==(got==n-1)))
            $fatal(1,"FAIL: read response buffer attributes/order");
        got=got+1;
    end
    task start;
        begin @(negedge clk);if(!ar_open) $fatal(1,"FAIL: buffer not idle");ar_fire=1;@(negedge clk);ar_fire=0;end
    endtask
    task feed;
        input integer count;
        begin
            for(p=0;p<count;p=p+1) begin
                @(negedge clk);in_valid=1;in_data=p+1000;in_id=p%16;in_resp=p%4;in_last=p==count-1;
                @(posedge clk);if(!in_ready) $fatal(1,"FAIL: slow consumer backpressured shared burst capture");
            end
            @(negedge clk);in_valid=0;in_last=0;
        end
    endtask
    initial begin
        repeat(5) @(negedge clk);rst=0;
        for(n=1;n<=32;n=n==1 ? 3 : n==3 ? 32 : 33) begin
            got=0;out_ready=0;start();feed(n);
            repeat(20) begin @(negedge clk);if(ar_open || !out_valid || out_data!==128'd1000) $fatal(1,"FAIL: buffer stalled output/AR gate");end
            while(got<n) begin @(negedge clk);out_ready=1;@(negedge clk);out_ready=0;end
            @(negedge clk);if(!ar_open) $fatal(1,"FAIL: buffer did not release");
        end
        // Cancel partially captured/replayed responses with common reset.
        start();@(negedge clk);in_valid=1;in_data=5;@(negedge clk);in_valid=0;rst=1;
        repeat(3) @(negedge clk);rst=0;#1;
        if(out_valid || !ar_open) $fatal(1,"FAIL: stale buffered response after reset");
        // Overlong malformed burst: drain through LAST, never overwrite/publish.
        checking=0;start();feed(33);repeat(5) @(negedge clk);
        if(!overflow_fault || out_valid || ar_open) $fatal(1,"FAIL: malformed oversized buffer response");
        $display("PASS: axi_read_burst_buffer capture/stall/attributes/reset/overflow all checks");$finish;
    end
    initial begin #100000;$fatal(1,"FAIL: read buffer timeout");end
endmodule
