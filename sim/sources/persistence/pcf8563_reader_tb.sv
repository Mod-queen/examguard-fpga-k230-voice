`timescale 1ns/1ps
module pcf8563_reader_tb;
    reg clk=0,rst=1,refresh_valid=0,result_ready=0;
    always #10 clk=~clk;
    wire refresh_ready,result_valid,known,fresh;
    wire [1:0] result_error;
    wire [71:0] snapshot;wire [31:0] age_cycles;
    wire [15:0] year;wire [7:0] month,day,hour,minute,second;wire [2:0] weekday;
    wire bus_req_valid,bus_rsp_ready;
    reg bus_req_ready=0,bus_rsp_valid=0;
    wire [6:0] bus_device;wire [1:0] bus_addr_bytes;wire [15:0] bus_address;
    wire [5:0] bus_wr_count,bus_rd_count;wire [255:0] bus_wr_data;
    reg [1:0] bus_error=0;reg [255:0] bus_rd_data=0;
    reg [71:0] good={8'h26,8'h10,8'd1,8'h19,8'h12,8'h34,8'h56,16'd0};
    pcf8563_reader #(.STALE_CYCLES(30),.MAX_READ_CYCLES(2000)) dut(.*);
    integer reqs=0,results=0;
    task automatic start;
        begin
            @(negedge clk);refresh_valid=1;@(posedge clk);while(!refresh_ready) @(posedge clk);
            @(negedge clk);refresh_valid=0;
        end
    endtask
    task automatic serve(input integer addr,input integer count,input [255:0] data,input integer error_code);
        reg [31:0] held;
        begin
            wait(bus_req_valid);#1;held={bus_device,bus_addr_bytes,bus_address,bus_rd_count};
            repeat(7) begin
                @(negedge clk);if(!bus_req_valid || {bus_device,bus_addr_bytes,bus_address,bus_rd_count}!==held)
                    $fatal(1,"FAIL: RTC request changed during backpressure");
            end
            if(bus_device!=7'h51 || bus_addr_bytes!=1 || bus_wr_count!=0 || bus_address!=addr || bus_rd_count!=count)
                $fatal(1,"FAIL: RTC transaction shape");
            bus_req_ready=1;@(negedge clk);bus_req_ready=0;
            repeat(9) @(negedge clk);bus_rd_data=data;bus_error=error_code;bus_rsp_valid=1;
            @(posedge clk);while(!bus_rsp_ready) @(posedge clk);
            @(negedge clk);bus_rsp_valid=0;reqs=reqs+1;
        end
    endtask
    task automatic consume(input integer err,input integer trusted);
        reg [71:0] held;
        begin
            wait(result_valid);#1;held=snapshot;
            repeat(8) begin @(negedge clk);
                if(!result_valid || snapshot!==held || result_error!=err || known!=trusted || refresh_ready)
                    $fatal(1,"FAIL: RTC result/trust mismatch");
            end
            result_ready=1;@(negedge clk);result_ready=0;results=results+1;
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        start();serve(0,9,{184'd0,good},0);serve(2,1,256'h56,0);consume(0,1);
        if(year!=2026 || month!=10 || day!=19 || second!=56 || !fresh) $fatal(1,"FAIL: RTC trusted date");
        repeat(40) @(negedge clk);if(fresh || !known) $fatal(1,"FAIL: stale RTC not distinguished");
        // Rollover must retry full snapshot, never mix old minutes/new seconds.
        start();serve(0,9,{184'd0,good},0);serve(2,1,256'h57,0);
        good[23:16]=8'h57;serve(0,9,{184'd0,good},0);serve(2,1,256'h57,0);consume(0,1);
        // VL and stopped records remain invalid, previous trusted raw retained.
        good[23]=1;start();serve(0,9,{184'd0,good},0);serve(2,1,256'hd7,0);consume(2,0);good[23]=0;
        start();serve(0,9,0,1);consume(1,0);
        // Bounded retries: 3 failed equality checks, not an endless polling lock.
        start();repeat(3) begin serve(0,9,{184'd0,good},0);serve(2,1,256'h58,0);end consume(3,0);
        start();serve(0,9,{184'd0,good},0);serve(2,1,256'h57,0);consume(0,1);
        // Equal seconds alone is insufficient after an arbitrarily long arbiter
        // stall (could wrap 60s): preserve ready/valid, finish as untrusted.
        start();wait(bus_req_valid);repeat(2100) @(negedge clk);
        serve(0,9,{184'd0,good},0);consume(3,0);
        @(negedge clk);rst=1;@(negedge clk);
        if(known || fresh || result_valid || bus_req_valid) $fatal(1,"FAIL: RTC reset");
        $display("PASS: pcf8563_reader results=%0d transactions=%0d burst/reread/rollover/VL/I2C-error/stale/reset",results,reqs);$finish;
    end
    initial begin #100000;$fatal(1,"FAIL: RTC reader timeout");end
endmodule
