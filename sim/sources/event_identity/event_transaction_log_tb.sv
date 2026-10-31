`timescale 1ns/1ps
module event_transaction_log_tb;
    reg clk=0,rst=1,event_valid=0,byte_ready=0;
    always #5 clk=~clk;
    reg [255:0] event_data=0;
    wire event_ready,byte_valid,byte_last;
    wire [7:0] byte_data;
    event_transaction_log dut(.*);
    integer seed=45,n,pos=0,got=0;
    reg checking=1,stalled=0;
    reg [8:0] held;
    string expected;
    function [255:0] record;
        input integer i;
        begin record={32'hac750001,32'h12345678,32'hffffffff,64'hffffffff00000000+i,64'h12345678ffffffff+i,32'h01003750};end
    endfunction
    always @(negedge clk) byte_ready=($random(seed)&7)!=0;
    always @(posedge clk) begin
        if(rst) stalled<=0;
        else begin
            if(stalled && (!byte_valid || {byte_last,byte_data}!==held)) $fatal(1,"FAIL: log holding byte");
            stalled<=byte_valid && !byte_ready;held<={byte_last,byte_data};
            if(checking && byte_valid && byte_ready) begin
                expected=$sformatf("ET,%064x\n",record(got));expected=expected.toupper();
                if(byte_data!==expected[pos] || byte_last!==(pos==67)) $fatal(1,"FAIL: log byte/identity pos=%0d",pos);
                if(byte_last) begin got=got+1;pos=0;end else pos=pos+1;
            end
        end
    end
    initial begin
        repeat(4) @(negedge clk);rst=0;
        for(n=0;n<40;n=n+1) begin
            event_valid=1;event_data=record(n);@(posedge clk);while(!event_ready) @(posedge clk);
            @(negedge clk);event_valid=0;event_data=~record(n);
        end
        wait(got==40);checking=0;@(negedge clk);event_valid=1;
        @(negedge clk);event_valid=0;repeat(12) @(negedge clk);rst=1;
        repeat(3) @(negedge clk);rst=0;#1;
        if(byte_valid || !event_ready) $fatal(1,"FAIL: log reset partial packet");
        $display("PASS: event_transaction_log full256bit/64hex/68byte ET random backpressure/reset");$finish;
    end
    initial begin #1000000;$fatal(1,"FAIL: log timeout");end
endmodule
