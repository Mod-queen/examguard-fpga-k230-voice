`timescale 1ns/1ps
module board_monitor_record_tb;
    reg clk=0,rst=1;always #10 clk=~clk;
    reg [96:0] monitor={1'b1,32'd1,64'h9990999055509770};reg monitor_valid=1;
    wire byte_valid,byte_last;wire [7:0] byte_data;reg byte_ready=1;
    integer fd,count=0;
    board_monitor_record #(.PERIOD_CYCLES(200),.STALE_CYCLES(50000000)) dut(
        .clk(clk),.rst(rst),.monitor(monitor),.monitor_valid(monitor_valid),.device_id(32'd1),.boot_id(32'd18),
        .seat_id(32'd6),.monotonic_ms(64'd1000),.straps_valid(1'b1),.switches(8'h85),.*);
    always @(posedge clk) if(!rst && byte_valid && byte_ready) begin
        $fwrite(fd,"%c",byte_data);if(byte_last) count=count+1;
    end
    initial begin
        fd=$fopen("board_monitor_records.txt","w");repeat(4) @(negedge clk);rst=0;
        wait(count==1);monitor_valid=0;wait(count==2);$fclose(fd);
        $display("PASS: board_monitor_record good/invalid two CRC packets");$finish;
    end
endmodule
