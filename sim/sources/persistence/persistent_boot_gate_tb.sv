`timescale 1ns/1ps
module persistent_boot_gate_tb;
    reg clk=0,rst=1,start=0,format_blank=0,store_cmd_ready=0,store_result_valid=0,store_loaded=0;
    always #10 clk=~clk;
    reg [31:0] device=1,store_boot=0;reg [255:0] initial_config=256'h123;
    reg [3:0] store_error=0;
    wire store_cmd_valid,store_result_ready,admission,done;
    wire [1:0] store_cmd;wire [31:0] store_device,boot_id;wire [255:0] store_config;wire [3:0] error;
    persistent_boot_gate dut(.*);
    integer i,checks=0;
    task automatic exercise(input integer formatting,input integer err,input integer valid_load,input integer bootnum,input integer admit);
        begin
            @(negedge clk);rst=1;start=0;repeat(3) @(negedge clk);rst=0;format_blank=formatting;
            start=1;@(negedge clk);start=0;
            repeat(8) @(negedge clk);
            if(!store_cmd_valid || store_cmd!=(formatting?3:1) || admission || store_device!=1 || store_config!=initial_config)
                $fatal(1,"FAIL: boot command/admission");
            store_cmd_ready=1;@(negedge clk);store_cmd_ready=0;
            repeat(8) @(negedge clk);if(admission) $fatal(1,"FAIL: boot before verified");
            store_error=err;store_loaded=valid_load;store_boot=bootnum;store_result_valid=1;
            @(negedge clk);store_result_valid=0;
            if(!done || admission!=admit || (admit && boot_id!=bootnum)) $fatal(1,"FAIL: boot result");
            start=1;repeat(30) @(negedge clk);start=0;
            if(store_cmd_valid || admission!=admit) $fatal(1,"FAIL: repeated start reallocated boot");checks=checks+1;
        end
    endtask
    initial begin
        exercise(0,0,1,7,1);exercise(1,0,1,1,1);
        for(i=1;i<10;i=i+1) exercise(0,i,0,9,0);
        exercise(0,0,0,1,0);exercise(0,0,1,0,0);
        $display("PASS: persistent_boot_gate checks=%0d verified-only/blank-explicit/all-errors/no-double-allocation",checks);$finish;
    end
endmodule
