`timescale 1ns/1ps
module eeprom_page_writer_tb;
    reg clk=0,rst=1,write_valid=0,result_ready=0;
    always #10 clk=~clk;
    wire write_ready,result_valid;wire [2:0] result_error;
    reg [12:0] write_address=0;reg [5:0] write_count=0;reg [255:0] write_data=0;
    wire bus_req_valid,bus_rsp_ready;
    reg bus_req_ready=0,bus_rsp_valid=0;
    wire [6:0] bus_device;wire [1:0] bus_addr_bytes;wire [15:0] bus_address;
    wire [5:0] bus_wr_count,bus_rd_count;wire [255:0] bus_wr_data;
    reg [1:0] bus_error=0;reg [255:0] bus_rd_data=0;
    eeprom_page_writer #(.MAX_POLLS(3)) dut(.*);
    integer transactions=0,results=0,i;
    reg [255:0] original,readback;
    task automatic start(input integer addr,input integer count);
        begin
            @(negedge clk);write_address=addr;write_count=count;write_data=original;write_valid=1;
            @(posedge clk);while(!write_ready) @(posedge clk);
            @(negedge clk);write_valid=0;write_data=~original;write_address=1;write_count=1;
        end
    endtask
    task automatic serve(input integer addr,input integer addrlen,input integer wr,input integer rd,input integer err,input [255:0] returned);
        reg [290:0] held;
        begin
            wait(bus_req_valid);#1;held={bus_address,bus_addr_bytes,bus_wr_count,bus_rd_count,bus_wr_data};
            repeat(5) begin @(negedge clk);
                if(!bus_req_valid || {bus_address,bus_addr_bytes,bus_wr_count,bus_rd_count,bus_wr_data}!==held)
                    $fatal(1,"FAIL: page request not stable");
            end
            if(bus_device!=7'h50 || bus_address!=addr || bus_addr_bytes!=addrlen || bus_wr_count!=wr || bus_rd_count!=rd ||
                (wr!=0 && bus_wr_data!==original)) $fatal(1,"FAIL: EEPROM transaction shape/data");
            bus_req_ready=1;@(negedge clk);bus_req_ready=0;repeat(7) @(negedge clk);
            bus_error=err;bus_rd_data=returned;bus_rsp_valid=1;
            @(posedge clk);while(!bus_rsp_ready) @(posedge clk);
            @(negedge clk);bus_rsp_valid=0;transactions=transactions+1;
        end
    endtask
    task automatic consume(input integer err);
        begin
            wait(result_valid);repeat(8) begin @(negedge clk);
                if(result_error!=err || !result_valid || write_ready || bus_req_valid) $fatal(1,"FAIL: EEPROM result %0d expected %0d",result_error,err);
            end
            result_ready=1;@(negedge clk);result_ready=0;results=results+1;
        end
    endtask
    initial begin
        for(i=0;i<32;i=i+1) original[i*8 +: 8]=i*11+9;
        repeat(4) @(negedge clk);rst=0;
        start(8160,32);serve(8160,2,32,0,0,0);
        serve(8160,0,0,0,1,0);serve(8160,0,0,0,1,0);serve(8160,0,0,0,0,0);
        serve(8160,2,0,32,0,original);consume(0);
        // Last address and one-byte verify ignores unused response bytes.
        start(8191,1);serve(8191,2,1,0,0,0);serve(8191,0,0,0,0,0);
        readback=~original;readback[7:0]=original[7:0];serve(8191,2,0,1,0,readback);consume(0);
        start(31,2);consume(2);start(0,33);consume(2);start(0,0);consume(2);
        // Busy forever bounded; no write replay.
        start(0,1);serve(0,2,1,0,0,0);repeat(3) serve(0,0,0,0,1,0);consume(3);
        start(0,1);serve(0,2,1,0,2,0);consume(1);
        // ACKed but WP/incorrect stored byte must NOT be committed.
        start(32,32);serve(32,2,32,0,0,0);serve(32,0,0,0,0,0);
        serve(32,2,0,32,0,~original);consume(4);
        // Reset while response is in flight: service drops old completion.
        start(64,2);wait(bus_req_valid);@(negedge clk);rst=1;@(negedge clk);
        if(result_valid || bus_req_valid) $fatal(1,"FAIL: reset kept EEPROM request");rst=0;
        $display("PASS: eeprom_page_writer results=%0d transactions=%0d page-tail/limit/poll-bound/verify-WP/errors/stalls/reset",results,transactions);$finish;
    end
    initial begin #100000;$fatal(1,"FAIL: EEPROM page service timeout");end
endmodule
