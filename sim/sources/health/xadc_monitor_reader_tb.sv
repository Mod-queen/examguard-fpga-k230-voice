`timescale 1ns/1ps
module xadc_monitor_reader_tb;
    reg clk=0,rst=1,eos=0,drdy=0;always #2.5 clk=~clk;
    reg [15:0] drp_data=0;wire den,valid,fault;wire [6:0] daddr;
    wire [31:0] sequence_id;wire [63:0] samples;wire [11:0] temperature;
    xadc_monitor_reader #(.TIMEOUT_CYCLES(30)) dut(.*);
    integer n;reg [63:0] before_samples;
    initial begin
        repeat(4) @(negedge clk);rst=0;
        for(integer pass=0;pass<3;pass=pass+1) begin
            before_samples=samples;
            @(negedge clk);eos=1;@(negedge clk);eos=0;
            for(n=0;n<4;n=n+1) begin
                wait(den);#1;if(daddr!=(n==3?6:n)) $fatal(1,"FAIL: shared DRP address");
                @(negedge clk);repeat(3+n) @(negedge clk);
                if(samples!==before_samples) $fatal(1,"FAIL: partial telemetry published");
                drp_data=(pass<<12)+(n<<8)+16'h50;drdy=1;@(negedge clk);drdy=0;
            end
            #1;if(!valid || sequence_id!=pass+1 || temperature!=(pass<<8)+5) $fatal(1,"FAIL: monitor publication/temp");
        end
        @(negedge clk);eos=1;@(negedge clk);eos=0;repeat(40) @(negedge clk);
        if(!fault || valid || den) $fatal(1,"FAIL: timeout stale masquerades valid");
        rst=1;repeat(4) @(negedge clk);rst=0;#1;
        if(fault || valid || sequence_id) $fatal(1,"FAIL: reset recovery");
        $display("PASS: xadc_monitor_reader four addresses/atomic batches/temp/timeout/reset");$finish;
    end
    initial begin #10000;$fatal(1,"FAIL: XADC reader timeout");end
endmodule
