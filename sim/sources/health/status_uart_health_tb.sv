`timescale 1ns/1ps
module status_uart_health_tb;
    reg clk=0,rst=1;
    always #5 clk=~clk;
    reg [1023:0] evidence_health_data;
    reg [7:0] event_code=0;
    wire uart_txd,uart_busy;
    status_uart_tx #(.ENABLE_TIMER(1),.ENABLE_EVIDENCE_HEALTH(1),.CLK_FREQ_HZ(921600),.BAUD_RATE(115200),.STATUS_PERIOD_CYCLES(400)) dut(
        .clk(clk),.rst(rst),.status_valid(!rst),.status_frame_id(32'd42),.status_stage_id(4'd3),.status_risk_level(4'd0),.status_zone_id(4'd0),
        .status_timestamp(32'd7000),.status_event_code(event_code),.status_motion_pickup(8'd0),.status_motion_operation(8'd0),.status_motion_forbidden(8'd0),
        .event_device_id(32'd1),.event_boot_id(32'd2),.event_session_id(32'd3),.event_uid(64'd4),.event_seq(8'd5),.health_flags(8'd0),
        .remaining_s(16'd2700),.exam_duration_s(16'd2700),.evidence_health_data(evidence_health_data),.uart_txd(uart_txd),.uart_busy(uart_busy));
    localparam [1023:0] A={32'h02000070,32'd1,32'd2,32'd3,32'd4,32'd5,32'd6,32'h88,32'd1,32'd2,64'h12345678ffffffff,
        32'd10,32'd9,32'd8,32'd7,32'd6,32'd5,32'd4,32'd3,
        32'hc0000402,32'd11,32'd12,32'd13,32'd14,32'd15,32'd16,32'd17,32'd3,32'd18,32'd19,32'h010002fe};
    localparam [1023:0] B={32'h02000001,32'd1,32'd3,32'd3,32'd0,32'd0,32'd0,32'd0,32'd2,32'd3,64'h1234567900000001,608'd0,32'h010003fe};
    string line="",expect_a,expect_b;
    reg [7:0] ch;
    integer bitnum,got_a=0,got_b=0,got_al=0,got_ei=0,fd;
    initial forever begin
        @(negedge uart_txd);#120;
        for(bitnum=0;bitnum<8;bitnum=bitnum+1) begin ch[bitnum]=uart_txd;#80;end
        if(!uart_txd) $fatal(1,"FAIL: health UART framing");
        if(ch==10) begin
            $fwrite(fd,"%s\n",line);$fflush(fd);
            if(line==expect_a) got_a=got_a+1;
            else if(line==expect_b) got_b=got_b+1;
            else if(line=="AL,0000000042,0000007000,3,0,0,080") got_al=got_al+1;
            else if(line=="EI,00000001,00000002,00000003,0000000000000004,005") got_ei=got_ei+1;
            else $fatal(1,"FAIL: health UART torn/malformed line len=%0d: %s",line.len(),line);
            line="";
        end else line={line,ch};
    end
    initial begin
        fd=$fopen("health_uart.txt","w");if(!fd) $fatal(1,"FAIL: UART trace open");
        expect_a=$sformatf("ST,0000000042,3,0,0,0000007000,000,000,000,000,000,02700,02700,%0256x",A);
        expect_b=$sformatf("ST,0000000042,3,0,0,0000007000,080,000,000,000,000,02700,02700,%0256x",B);
        expect_a=expect_a.toupper();expect_b=expect_b.toupper();
        evidence_health_data=A;repeat(5) @(negedge clk);rst=0;
        wait(dut.tx_state==3 && dut.byte_index==100);
        @(negedge clk);evidence_health_data=B;event_code=80;
        wait(got_a==1 && got_b>=1 && got_al==1 && got_ei==1);
        $fclose(fd);
        $display("PASS: status_uart_health actual wire 320bytes ST extension immutable while changing stats; AL/EI boundaries preserved");$finish;
    end
    initial begin #10000000;$fatal(1,"FAIL: health UART timeout a=%0d b=%0d al=%0d ei=%0d",got_a,got_b,got_al,got_ei);end
endmodule
