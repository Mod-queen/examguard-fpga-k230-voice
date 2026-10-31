`timescale 1ns/1ps
module eeprom_record_codec_tb;
    reg clk=0,rst=1,req_valid=0,encode=0,result_ready=0;
    always #10 clk=~clk;
    wire req_ready,result_valid,record_ok;
    reg [511:0] in_body=0;reg [255:0] in_commit=0;
    reg [31:0] device=1,generation=1,boot=1;reg [255:0] config_data=256'habcdef123;
    wire [511:0] body;wire [255:0] commit_page;
    eeprom_record_codec dut(.*);
    reg [511:0] saved_body;reg [255:0] saved_commit;
    integer checks=0,i;
    task automatic run(input integer enc,input integer ok);
        reg [767:0] held;
        begin
            @(negedge clk);encode=enc;req_valid=1;
            @(posedge clk);while(!req_ready) @(posedge clk);
            @(negedge clk);req_valid=0;wait(result_valid);#1;
            if(record_ok!==1'(ok)) $fatal(1,"FAIL: codec expected%0d got%0d",ok,record_ok);
            held={body,commit_page};repeat(3) begin @(negedge clk);
                if(!result_valid || {body,commit_page}!==held) $fatal(1,"FAIL: codec unstable result");
            end
            result_ready=1;@(negedge clk);result_ready=0;checks=checks+1;
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;run(1,1);saved_body=body;saved_commit=commit_page;
        in_body=saved_body;in_commit=saved_commit;run(0,1);
        for(i=0;i<768;i=i+1) begin
            in_body=saved_body;in_commit=saved_commit;
            if(i<512) in_body[i]=!in_body[i];else in_commit[i-512]=!in_commit[i-512];
            run(0,0);
        end
        device=0;run(1,0);device=1;boot=0;run(1,0);boot=1;generation=0;run(1,0);
        $display("PASS: eeprom_record_codec checks=%0d all768singlebit-corruptions/zeroIDs/response-hold",checks);$finish;
    end
    initial begin #10000000;$fatal(1,"FAIL: codec timeout");end
endmodule
