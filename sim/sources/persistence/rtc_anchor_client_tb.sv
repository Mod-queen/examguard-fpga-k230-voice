`timescale 1ns/1ps
module rtc_anchor_client_tb;
    reg clk=0,rst=1,boot_admission=1,refresh_valid=0,byte_ready=0;
    always #10 clk=~clk;
    reg [31:0] device_id=1,boot_id=7;
    reg [63:0] monotonic_ms=64'h100000010;
    wire refresh_ready,known,fresh,byte_valid,byte_last,bus_req_valid,bus_rsp_ready;
    wire [31:0] age_cycles;wire [7:0] byte_data;
    wire [6:0] bus_device;wire [1:0] bus_addr_bytes;wire [15:0] bus_address;
    wire [5:0] bus_wr_count,bus_rd_count;wire [255:0] bus_wr_data;
    reg bus_req_ready=0,bus_rsp_valid=0;reg [1:0] bus_error=0;reg [255:0] bus_rd_data=0;
    rtc_anchor_client #(.STALE_CYCLES(5000),.MAX_READ_CYCLES(500)) dut(.*);
    integer fd,records=0,count=0;
    reg [31:0] random_state=32'h1234ac75;
    always @(negedge clk) begin
        random_state=random_state^(random_state<<13);random_state=random_state^(random_state>>17);random_state=random_state^(random_state<<5);
        byte_ready=random_state[1] || random_state[4];
    end
    always @(posedge clk) if(!rst && byte_valid && byte_ready) begin
        $fwrite(fd,"%c",byte_data);count=count+1;
        if(byte_last) begin
            if(count!=132) $fatal(1,"FAIL: combined RTC anchor record length");
            records=records+1;count=0;
        end
    end
    task automatic start;
        begin
            wait(refresh_ready);@(negedge clk);refresh_valid=1;@(negedge clk);refresh_valid=0;
        end
    endtask
    task automatic serve(input integer address,input integer count,input [255:0] payload,input integer err);
        begin
            wait(bus_req_valid);repeat(8) @(negedge clk);
            if(bus_device!=7'h51 || bus_addr_bytes!=1 || bus_wr_count || bus_address!=address || bus_rd_count!=count)
                $fatal(1,"FAIL: combined readonly bus shape");
            bus_req_ready=1;@(negedge clk);bus_req_ready=0;repeat(8) @(negedge clk);
            bus_rd_data=payload;bus_error=err;bus_rsp_valid=1;
            @(posedge clk);while(!bus_rsp_ready) @(posedge clk);
            @(negedge clk);bus_rsp_valid=0;
        end
    endtask
    initial begin
        fd=$fopen("rtc_anchor_client_records.txt","w");repeat(5) @(negedge clk);rst=0;
        start;serve(0,9,256'h261002201820350000,0);
        @(negedge clk);monotonic_ms=64'h100000019;serve(2,1,256'h35,0);
        wait(records==1);if(!known || !fresh) $fatal(1,"FAIL: combined trusted anchor missing");
        @(negedge clk);monotonic_ms=300;
        start;@(negedge clk);monotonic_ms=310;serve(0,9,0,1);
        wait(records==2);if(known || fresh) $fatal(1,"FAIL: combined read failure trusted");
        repeat(5) @(negedge clk);$fclose(fd);
        $display("PASS: rtc_anchor_client actualReader+anchor+CRCRecord busBackpressure/valid+I2Cfail/randomStream2x132");$finish;
    end
    initial begin #1000000;$fatal(1,"FAIL: RTC anchor client timeout");end
endmodule
