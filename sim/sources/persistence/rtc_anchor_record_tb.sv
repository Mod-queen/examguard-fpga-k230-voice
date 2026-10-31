`timescale 1ns/1ps
module rtc_anchor_record_tb;
    reg clk=0,rst=1,result_valid=0,byte_ready=0;
    always #10 clk=~clk;
    wire result_ready,byte_valid,byte_last;wire [7:0] byte_data;
    reg [2:0] result_error=0;
    reg [31:0] anchor_device=1,anchor_boot=7,anchor_sequence=1;
    reg [63:0] lower_ms=64'h100000010,upper_ms=64'h100000019;
    reg [71:0] rtc_raw=72'h261002201820350000;
    rtc_anchor_record dut(.*);
    reg [31:0] random_state=32'hbcdf1234;
    integer fd,bytes_received=0,records=0;
    reg stalled=0;reg [8:0] held;
    always @(negedge clk) begin
        random_state=random_state^(random_state<<13);random_state=random_state^(random_state>>17);random_state=random_state^(random_state<<5);
        byte_ready=random_state[0] || random_state[3];
    end
    always @(posedge clk) if(!rst) begin
        if(stalled && (!byte_valid || {byte_last,byte_data}!==held)) $fatal(1,"FAIL: RTC anchor stream changed under stall");
        stalled=byte_valid && !byte_ready;held={byte_last,byte_data};
        if(byte_valid && byte_ready) begin
            $fwrite(fd,"%c",byte_data);bytes_received=bytes_received+1;
            if(byte_last) begin
                if(bytes_received!=132 || byte_data!=10) $fatal(1,"FAIL: RA record boundary");
                records=records+1;bytes_received=0;
            end
        end
    end
    task automatic send;
        begin
            wait(result_ready);@(negedge clk);result_valid=1;
            @(negedge clk);result_valid=0;
        end
    endtask
    initial begin
        fd=$fopen("rtc_anchor_records.txt","w");repeat(5) @(negedge clk);rst=0;
        send;
        // Change producer payload while CRC/output are active; immutable record.
        lower_ms=300;upper_ms=310;anchor_sequence=2;result_error=1;rtc_raw=0;
        wait(records==1);send;
        wait(records==2);repeat(5) @(negedge clk);$fclose(fd);
        // Reset cancels unsent record, not an abbreviated success line.
        send;wait(byte_valid);@(negedge clk);rst=1;stalled=0;
        @(negedge clk);if(byte_valid || result_ready) $fatal(1,"FAIL: RA reset");
        $display("PASS: rtc_anchor_record immutable2x132/CRCstream/randomBackpressure/heldLAST/resetCancel");$finish;
    end
    initial begin #1000000;$fatal(1,"FAIL: RA record timeout");end
endmodule
