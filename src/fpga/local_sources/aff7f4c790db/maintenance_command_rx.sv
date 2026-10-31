`timescale 1ns/1ps
// Fixed MC,<64B hex> LF framing. Byte stream after the existing UART RX.
// Bad framing/CRC is dropped; held command is immutable until consumed. No
// automatic write retry. Bytes of a second command while full are discarded.
module maintenance_command_rx(
    input wire clk,rst,input wire rx_valid,input wire [7:0] rx_data,
    output reg command_valid,input wire command_ready,output reg [511:0] command_data,
    output reg [31:0] rejected_lines
);
    reg [2:0] state;
    reg [7:0] index;
    reg [511:0] buffer_data;
    reg [31:0] crc;
    reg [3:0] high_nibble;
    wire hex_valid=(rx_data>="0" && rx_data<="9") || (rx_data>="A" && rx_data<="F") || (rx_data>="a" && rx_data<="f");
    wire [3:0] nibble=rx_data<="9" ? rx_data-"0" : rx_data<="F" ? rx_data-"A"+10 : rx_data-"a"+10;
    function automatic [31:0] crc_byte(input [31:0] old,input [7:0] b);
        reg [31:0] c;integer k;
        begin c=old^{24'd0,b};for(k=0;k<8;k=k+1) c=c[0]?(c>>1)^32'hedb88320:c>>1;crc_byte=c;end
    endfunction
    always @(posedge clk) begin
        if(rst) begin state<=0;index<=0;buffer_data<=0;crc<=32'hffffffff;high_nibble<=0;
            command_valid<=0;command_data<=0;rejected_lines<=0;end
        else begin
            if(command_valid && command_ready) command_valid<=0;
            if(rx_valid) case(state)
                0:if(rx_data=="M") state<=1;else if(rx_data!=10) state<=5;
                1:if(rx_data=="C") state<=2;else state<=rx_data==10?0:5;
                2:if(rx_data==",") begin state<=3;index<=0;crc<=32'hffffffff;end else state<=rx_data==10?0:5;
                3:if(hex_valid) begin
                    buffer_data[511-index*4 -: 4]<=nibble;
                    if(!index[0]) high_nibble<=nibble;
                    else if(index<120) crc<=crc_byte(crc,{high_nibble,nibble});
                    if(index==127) state<=4;else index<=index+1'b1;
                end else begin state<=rx_data==10?0:5;
                    if(rejected_lines!=32'hffffffff) rejected_lines<=rejected_lines+1'b1;end
                4:begin
                    if(rx_data==10 && buffer_data[511:464]==48'h4d4301010040 && buffer_data[31:0]==~crc && !command_valid) begin
                        command_valid<=1;command_data<=buffer_data;
                    end else if(rejected_lines!=32'hffffffff) rejected_lines<=rejected_lines+1'b1;
                    state<=rx_data==10?0:5;
                end
                5:if(rx_data==10) state<=0;
                default:state<=0;
            endcase
        end
    end
endmodule
