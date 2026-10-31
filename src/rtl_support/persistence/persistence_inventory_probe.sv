`timescale 1ns/1ps
// READ ONLY inventory before any EEPROM formatting/RTC clock setting.
// PS v1 type1 binary UART report 284B: header6/status9/RTC9/EEPROM256/CRC4.
// EEPROM reads 0x1e00..0x1eff, RTC00..08. Never emits an I2C data write.
module persistence_inventory_probe #(
    parameter integer QUARTER_CYCLES=125,TIMEOUT_CYCLES=500000,
    parameter integer STARTUP_CYCLES=2500000,UART_BAUD=115200
)(
    input wire clk,rst,input wire scl_i,sda_i,output wire scl_low,sda_low,
    output wire uart_txd,output reg done
);
    localparam DELAY=0,ISSUE=1,WAIT=2,COPY=3,CRC=4,TX=5,TXBUSY=6,TXDONE=7,FINISHED=8;
    reg [3:0] state,transaction;
    reg [31:0] startup;
    reg [5:0] copy_index;
    reg [8:0] index;
    reg [255:0] response;
    reg [71:0] errors;
    reg [31:0] crc;
    (* ram_style="distributed" *) reg [7:0] bytes[0:264];
    wire req_ready,rsp_valid;
    wire [1:0] rsp_error;wire [255:0] rsp_data;
    wire [15:0] address=transaction==0?16'd0:16'h1e00+({12'd0,transaction}-1)*16'd32;
    i2c_register_master #(.QUARTER_CYCLES(QUARTER_CYCLES),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) master(
        .clk(clk),.rst(rst),.req_valid(state==ISSUE),.req_ready(req_ready),
        .req_device(transaction==0?7'h51:7'h50),.req_addr_bytes(transaction==0?2'd1:2'd2),
        .req_address(address),.req_wr_count(6'd0),.req_rd_count(transaction==0?6'd9:6'd32),.req_wr_data(256'd0),
        .rsp_valid(rsp_valid),.rsp_ready(state==WAIT),.rsp_error(rsp_error),.rsp_rd_data(rsp_data),
        .scl_i(scl_i),.sda_i(sda_i),.scl_low(scl_low),.sda_low(sda_low));
    wire [8:0] data_address=index-9'd15;
    reg [7:0] report_byte;
    always @* begin
        report_byte=0;
        case(index)
            0:report_byte=8'h50;
            1:report_byte=8'h53;
            2:report_byte=1;
            3:report_byte=1;
            4:report_byte=1;
            5:report_byte=8'h1c; //284BE
            default:if(index<15) report_byte=errors[(index-6)*8 +: 8];
                else if(index<280) report_byte=bytes[data_address];
                else case(index)
                    280:report_byte=~crc[31:24];281:report_byte=~crc[23:16];
                    282:report_byte=~crc[15:8];283:report_byte=~crc[7:0];
                endcase
        endcase
    end
    function automatic [31:0] step(input [31:0] old,input [7:0] b);
        reg [31:0] c;integer k;
        begin c=old^{24'd0,b};for(k=0;k<8;k=k+1) c=c[0]?(c>>1)^32'hedb88320:c>>1;step=c;end
    endfunction
    wire uart_busy;
    uart_tx #(.CLK_FREQ_HZ(50000000),.BAUD_RATE(UART_BAUD)) uart(
        .clk(clk),.rst(rst),.tx_start(state==TX),.tx_data(report_byte),.tx(uart_txd),.busy(uart_busy));
    wire [8:0] copy_addr=transaction==0?{3'd0,copy_index}:9'd9+({5'd0,transaction}-1)*9'd32+copy_index;
    always @(posedge clk) if(!rst && state==COPY) bytes[copy_addr]<=response[copy_index*8 +: 8];
    always @(posedge clk) begin
        if(rst) begin state<=DELAY;transaction<=0;startup<=0;copy_index<=0;index<=0;response<=0;errors<=0;crc<=0;done<=0;end
        else case(state)
            DELAY:if(startup==STARTUP_CYCLES-1) state<=ISSUE;else startup<=startup+1'b1;
            ISSUE:if(req_ready) state<=WAIT;
            WAIT:if(rsp_valid) begin
                errors[transaction*8 +: 8]<={6'd0,rsp_error};response<=rsp_error==0?rsp_data:256'd0;
                copy_index<=0;state<=COPY;
            end
            COPY:if(copy_index==(transaction==0?8:31)) begin
                if(transaction==8) begin index<=0;crc<=32'hffffffff;state<=CRC;end
                else begin transaction<=transaction+1'b1;state<=ISSUE;end
            end else copy_index<=copy_index+1'b1;
            CRC:begin
                crc<=step(crc,report_byte);
                if(index==279) begin index<=0;state<=TX;end else index<=index+1'b1;
            end
            TX:state<=TXBUSY;
            TXBUSY:if(uart_busy) state<=TXDONE;
            TXDONE:if(!uart_busy) begin
                if(index==283) begin state<=FINISHED;done<=1;end
                else begin index<=index+1'b1;state<=TX;end
            end
            FINISHED:state<=FINISHED;
        endcase
    end
endmodule
