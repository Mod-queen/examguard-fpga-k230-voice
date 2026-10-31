`timescale 1ns/1ps
module rtc_time_anchor_tb;
    reg clk=0,rst=1,boot_admission=0,refresh_valid=0,result_ready=0;
    always #10 clk=~clk;
    reg [31:0] device_id=1,boot_id=7;
    reg [63:0] monotonic_ms=1000;
    always @(posedge clk) if(!rst) monotonic_ms<=monotonic_ms+1'b1; // accelerated source time
    wire refresh_ready,result_valid,known,fresh;
    wire [2:0] result_error;wire [31:0] anchor_device,anchor_boot,anchor_sequence,age_cycles;
    wire [63:0] lower_ms,upper_ms;wire [71:0] rtc_raw;
    wire bus_req_valid,bus_rsp_ready;reg bus_req_ready=0,bus_rsp_valid=0;
    wire [6:0] bus_device;wire [1:0] bus_addr_bytes;wire [15:0] bus_address;
    wire [5:0] bus_wr_count,bus_rd_count;wire [255:0] bus_wr_data;
    reg [1:0] bus_error=0;reg [255:0] bus_rd_data=0;
    rtc_time_anchor #(.STALE_CYCLES(30),.MAX_READ_CYCLES(500)) dut(.*);
    reg [71:0] calendar={8'h26,8'h10,8'd2,8'h20,8'h18,8'h20,8'h35,16'd0};
    reg [63:0] expected_lower;
    integer checks=0;
    task automatic start;
        begin
            @(negedge clk);refresh_valid=1;expected_lower=monotonic_ms;
            @(posedge clk);while(!refresh_ready) @(posedge clk);
            @(negedge clk);refresh_valid=0;
        end
    endtask
    task automatic serve(input integer address,input integer count,input [255:0] data,input integer err);
        begin
            wait(bus_req_valid);repeat(8) @(negedge clk);
            if(bus_device!=7'h51 || bus_addr_bytes!=1 || bus_address!=address || bus_rd_count!=count || bus_wr_count)
                $fatal(1,"FAIL: anchor changed readonly RTC request");
            bus_req_ready=1;@(negedge clk);bus_req_ready=0;
            repeat(10) @(negedge clk);bus_error=err;bus_rd_data=data;bus_rsp_valid=1;
            @(posedge clk);while(!bus_rsp_ready) @(posedge clk);
            @(negedge clk);bus_rsp_valid=0;
        end
    endtask
    task automatic consume(input integer err);
        reg [327:0] held;
        begin
            wait(result_valid);#1;
            if(result_error!=err || known!=(err==0) || lower_ms!=expected_lower || upper_ms<=lower_ms ||
                anchor_device!=1 || (err==0 && (rtc_raw!==calendar || !fresh)))
                $fatal(1,"FAIL: anchor qualification/bracket/raw err=%0d/%0d",result_error,err);
            held={result_error,anchor_device,anchor_boot,anchor_sequence,lower_ms,upper_ms,rtc_raw};
            repeat(12) begin
                @(negedge clk);
                if(!result_valid || refresh_ready || held!=={result_error,anchor_device,anchor_boot,anchor_sequence,lower_ms,upper_ms,rtc_raw})
                    $fatal(1,"FAIL: anchor payload changed under backpressure");
            end
            result_ready=1;@(negedge clk);result_ready=0;checks=checks+1;
        end
    endtask
    initial begin
        repeat(5) @(negedge clk);rst=0;refresh_valid=1;
        repeat(10) @(negedge clk);
        if(refresh_ready || bus_req_valid || known) $fatal(1,"FAIL: anchor before persistent admission");
        refresh_valid=0;boot_admission=1;
        start;serve(0,9,{184'd0,calendar},0);serve(2,1,256'h35,0);consume(0);
        repeat(35) @(negedge clk);if(fresh || !known) $fatal(1,"FAIL: anchor stale/unknown conflated");
        // Clock setting backwards is a new independent anchor, never adjusts monotonic time.
        calendar[39:32]=8'h17;
        start;serve(0,9,{184'd0,calendar},0);serve(2,1,256'h35,0);consume(0);
        // Reader's bounded rollover retry expands bracket; no calendar mixing.
        start;serve(0,9,{184'd0,calendar},0);serve(2,1,256'h36,0);
        calendar[23:16]=8'h36;serve(0,9,{184'd0,calendar},0);serve(2,1,256'h36,0);consume(0);
        start;serve(0,9,0,1);consume(1);
        calendar[23]=1;start;serve(0,9,{184'd0,calendar},0);serve(2,1,256'hb6,0);consume(2);calendar[23]=0;
        // Identity changes during arbiter wait: result still observable, untrusted.
        start;boot_id=8;serve(0,9,{184'd0,calendar},0);serve(2,1,256'h36,0);consume(4);boot_id=7;
        start;serve(0,9,{184'd0,calendar},0);serve(2,1,256'h36,0);consume(0);
        if(anchor_sequence!=7) $fatal(1,"FAIL: anchor sequence not incremented per result");
        @(negedge clk);dut.anchor_sequence=32'hfffffffe;
        start;serve(0,9,{184'd0,calendar},0);serve(2,1,256'h36,0);consume(0);
        if(anchor_sequence!=32'hffffffff || refresh_ready) $fatal(1,"FAIL: anchor sequence exhaustion reused identity");
        rst=1;repeat(3) @(negedge clk);
        if(known || result_valid || bus_req_valid) $fatal(1,"FAIL: anchor reset leaked old boot");
        $display("PASS: rtc_time_anchor readerComposition bracketing/heldResult/stale/backwardCalendar/rollover/I2C/VL/bootChange/reset results=%0d",checks);$finish;
    end
    initial begin #1000000;$fatal(1,"FAIL: anchor timeout");end
endmodule
