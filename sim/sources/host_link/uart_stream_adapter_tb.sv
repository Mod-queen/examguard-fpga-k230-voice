`timescale 1ns/1ps
module uart_stream_adapter_tb;
    reg clk=0,rst=1,tx_start=0,tx_last=0,stream_ready=0;
    reg [7:0] tx_data=0;
    always #5 clk=~clk;
    wire tx,busy,stream_valid,stream_last;
    wire [7:0] stream_data;
    uart_stream_adapter dut(.*);
    integer i,n=0;
    initial begin
        repeat(4) @(negedge clk);rst=0;
        for(i=0;i<25;i=i+1) begin
            tx_start=1;tx_data=i;tx_last=i==24;@(negedge clk);tx_start=0;tx_data=~i;
            repeat(7) begin @(negedge clk);if(!busy || !stream_valid || stream_data!==8'(i) || stream_last!==(i==24)) $fatal(1,"FAIL: adapter holding byte");end
            stream_ready=1;@(negedge clk);stream_ready=0;#1;if(busy) $fatal(1,"FAIL: adapter ack");
        end
        tx_start=1;@(negedge clk);tx_start=0;rst=1;@(negedge clk);rst=0;#1;
        if(busy || stream_valid) $fatal(1,"FAIL: adapter reset");
        $display("PASS: uart_stream_adapter start/busy holding/data/last/reset");$finish;
    end
endmodule
