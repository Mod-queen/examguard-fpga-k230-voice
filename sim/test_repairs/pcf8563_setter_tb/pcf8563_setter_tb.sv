`timescale 1ns/1ps
module pcf8563_setter_tb;
    reg clk=0,rst=1,set_valid=0,maintenance=1,authorize=1,result_ready=0;
    always #10 clk=~clk;
    reg [55:0] calendar_data;
    wire set_ready,result_valid,write_attempted;
    wire [3:0] result_error;wire [1:0] recovery_error;wire [71:0] snapshot;
    wire bus_req_valid,bus_rsp_ready;
    reg bus_req_ready=0,bus_rsp_valid=0;
    wire [6:0] bus_device;wire [1:0] bus_addr_bytes;
    wire [15:0] bus_address;wire [5:0] bus_wr_count,bus_rd_count;wire [255:0] bus_wr_data;
    reg [1:0] bus_error=0;reg [255:0] bus_rd_data=0;
    reg [7:0] media[0:15];
    reg [55:0] after_tick;
    integer requests=0,writes=0,results=0,index=0;
    integer error_request=0,tear_request=0,recovery_fail=0,wrong_readback=0,run_mode=0;
    reg model_busy=0;
    reg [111:0] oracle [0:1199];
    pcf8563_setter dut(.*);

    task automatic transact;
        reg [6:0] dev;reg [1:0] addrbytes;
        reg [15:0] addr;reg [5:0] wc,rc;reg [255:0] data,answer;
        integer err,k;
        begin
            wait(bus_req_valid);#1;
            dev=bus_device;addrbytes=bus_addr_bytes;addr=bus_address;
            wc=bus_wr_count;rc=bus_rd_count;data=bus_wr_data;answer=0;
            repeat(3) begin
                @(negedge clk);
                if(!bus_req_valid || {bus_device,bus_addr_bytes,bus_address,bus_wr_count,bus_rd_count,bus_wr_data}
                    !=={dev,addrbytes,addr,wc,rc,data}) $fatal(1,"FAIL: request unstable");
            end
            if(dev!=7'h51 || addrbytes!=1 || addr+wc>9 || addr+rc>9 || wc>7 || (wc!=0&&rc!=0))
                $fatal(1,"FAIL: RTC setter bus shape/outside RTC");
            bus_req_ready=1;@(negedge clk);bus_req_ready=0;requests=requests+1;index=index+1;
            model_busy=1;
            err=(index==error_request)?1:0;
            if(recovery_fail && index==error_request+1) err=2;
            if(wc!=0) begin
                writes=writes+1;
                if(!err || index==tear_request) begin
                    for(k=0;k<wc;k=k+1)
                        if(index!=tear_request || k<3) media[addr+k]=data[k*8+:8];
                    if(addr==0 && data[7:0]==0 && run_mode!=0) begin
                        for(k=0;k<7;k=k+1) media[k+2]=after_tick[k*8+:8];
                    end
                end
            end else begin
                for(k=0;k<rc;k=k+1) answer[k*8+:8]=media[addr+k];
                if(index==4 && wrong_readback) answer[16]=~answer[16];
            end
            repeat(5) @(negedge clk);
            bus_error=err;bus_rd_data=answer;bus_rsp_valid=1;
            @(posedge clk);while(!bus_rsp_ready) @(posedge clk);
            @(negedge clk);bus_rsp_valid=0;model_busy=0;
        end
    endtask
    initial forever begin transact();end
    task automatic initialize;
        integer k;
        begin
            @(negedge clk);rst=1;set_valid=0;result_ready=0;
            repeat(4) @(negedge clk);rst=0;
            index=0;error_request=0;tear_request=0;recovery_fail=0;
            wrong_readback=0;run_mode=0;maintenance=1;authorize=1;
            for(k=0;k<16;k=k+1) media[k]=8'h80+k;
            media[0]=0;
            calendar_data=56'h26100321123456;
        end
    endtask
    task automatic start;
        begin
            @(negedge clk);set_valid=1;@(posedge clk);while(!set_ready) @(posedge clk);
            @(negedge clk);set_valid=0;
            // Request payload/authorization changes after acceptance must not tear writes.
            calendar_data=0;authorize=0;
        end
    endtask
    task automatic consume(input integer expected_error,input integer expected_writes,input integer recovery);
        reg [71:0] held;integer request_count;
        begin
            wait(result_valid);#1;held=snapshot;request_count=requests;
            repeat(8) begin
                @(negedge clk);
                if(!result_valid || result_error!=expected_error || recovery_error!=recovery ||
                    snapshot!==held || set_ready || requests!=request_count || write_attempted!=(expected_writes!=0))
                    $fatal(1,"FAIL: result/held/error expected=%0d got=%0d recovery=%0d index=%0d",expected_error,result_error,recovery_error,index);
            end
            if(media[1]!==8'h81 || media[9]!==8'h89 || media[15]!==8'h8f)
                $fatal(1,"FAIL: setter modified alarm/control2/unrelated registers");
            result_ready=1;@(negedge clk);result_ready=0;results=results+1;
        end
    endtask
    integer k,base_requests;
    reg [55:0] target;
    initial begin
        $readmemh("rtc_setter_monthends_20261021.mem",oracle);
        for(k=0;k<1200;k=k+1)
            if(dut.next_second(oracle[k][111:56])!==oracle[k][55:0])
                $fatal(1,"FAIL: independent datetime rollover oracle index=%0d",k);
        initialize();target=calendar_data;start();consume(0,1,0);
        if(snapshot[71:16]!==target || media[0]!=0 || index!=7) $fatal(1,"FAIL: normal set verify");
        initialize();authorize=0;base_requests=requests;start();consume(1,0,0);
        if(requests!=base_requests) $fatal(1,"FAIL: unauthorized bus access");
        initialize();maintenance=0;base_requests=requests;start();consume(1,0,0);
        if(requests!=base_requests) $fatal(1,"FAIL: active exam bus access");
        // Impossible date, VL/century/reserved bits, weekday7 and illegal BCD.
        for(k=0;k<6;k=k+1) begin
            initialize();
            case(k)
                0:calendar_data=56'h26020330123456;
                1:calendar_data[7]=1;
                2:calendar_data[47]=1;
                3:calendar_data[37:32]=7;
                4:calendar_data[15:8]=8'h6a;
                5:calendar_data[31]=1;
            endcase
            base_requests=requests;start();consume(2,0,0);
            if(requests!=base_requests) $fatal(1,"FAIL: invalid calendar bus access");
        end
        initialize();media[0]=8'h80;start();consume(4,0,0);
        if(index!=1) $fatal(1,"FAIL: test-mode control overwritten");
        initialize();media[0]=8'h20;start();consume(0,1,0); // explicit request may repair stopped RTC
        // Inject failure into each operation before RUN, including uncertain STOP/date writes.
        for(k=1;k<=5;k=k+1) begin
            initialize();error_request=k;tear_request=k;start();consume(3,k!=1,0);
            if(index!=(k==1?1:k+1) || (k>1 && media[0]!=0)) $fatal(1,"FAIL: recovery sequence");
        end
        initialize();error_request=3;tear_request=3;recovery_fail=1;start();consume(3,1,2);
        if(media[0]!=8'h20 || index!=4) $fatal(1,"FAIL: failed recovery hidden/retried");
        initialize();wrong_readback=1;start();consume(5,1,0);
        if(media[0]!=0 || index!=5) $fatal(1,"FAIL: mismatch not recovered");
        initialize();error_request=6;start();consume(6,1,0);
        // One-second running readback may cross day/month/year, including leap day.
        for(k=0;k<4;k=k+1) begin
            initialize();run_mode=1;
            case(k)
                0:begin calendar_data=56'h24020328235959;after_tick=56'h24020429000000;end
                1:begin calendar_data=56'h26020328235959;after_tick=56'h26030401000000;end
                2:begin calendar_data=56'h26120631235959;after_tick=56'h27010001000000;end
                3:begin calendar_data=56'h26100321123459;after_tick=56'h26100321123500;end
            endcase
            start();consume(0,1,0);
            if(snapshot[71:16]!==after_tick) $fatal(1,"FAIL: boundary snapshot");
        end
        initialize();run_mode=1;after_tick=56'h26100321123458;start();consume(6,1,0);
        // System reset drops old result; no automatic write on restart.
        initialize();target=calendar_data;start();consume(0,1,0);
        @(negedge clk);rst=1;@(negedge clk);rst=0;base_requests=requests;
        repeat(20) @(negedge clk);
        if(result_valid || !set_ready || requests!=base_requests) $fatal(1,"FAIL: reset auto retry");
        $display("PASS: pcf8563_setter results=%0d bus=%0d writes=%0d 1200-month-end-oracle/auth/calendar/failure/recovery/readback/rollover/reset",results,requests,writes);
        $finish;
    end
    initial begin #5000000;$fatal(1,"FAIL: RTC setter timeout");end
endmodule
