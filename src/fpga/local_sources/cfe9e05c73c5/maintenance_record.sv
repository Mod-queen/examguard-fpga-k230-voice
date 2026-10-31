`timescale 1ns/1ps
// MR,<96B hex> LF; payload is first92B BE packed, CRC32 appended BE.
module maintenance_record(
    input wire clk,rst,input wire result_valid,output wire result_ready,
    input wire [735:0] payload,
    output wire byte_valid,byte_last,output wire [7:0] byte_data,input wire byte_ready
);
    reg [1:0] state;
    reg [767:0] held;
    reg [6:0] crc_index;reg [7:0] index;reg [31:0] crc;
    function automatic [31:0] crc_byte(input [31:0] old,input [7:0] b);
        reg [31:0] c;integer k;
        begin c=old^{24'd0,b};for(k=0;k<8;k=k+1) c=c[0]?(c>>1)^32'hedb88320:c>>1;crc_byte=c;end
    endfunction
    wire [3:0] nibble=held[767-(index-3)*4 -: 4];
    assign result_ready=!rst && state==0;
    assign byte_valid=!rst && state==2;
    assign byte_last=index==195;
    assign byte_data=index==0?"M":index==1?"R":index==2?",":index==195?8'h0a:
        nibble<10?8'h30+nibble:8'h41+nibble-10;
    always @(posedge clk) begin
        if(rst) begin state<=0;held<=0;crc<=32'hffffffff;crc_index<=0;index<=0;end
        else case(state)
            0:if(result_valid) begin held<={payload,32'd0};crc<=32'hffffffff;crc_index<=0;state<=1;end
            1:begin
                crc<=crc_byte(crc,held[767-crc_index*8 -: 8]);
                if(crc_index==91) begin held[31:0]<=~crc_byte(crc,held[767-crc_index*8 -: 8]);index<=0;state<=2;end
                else crc_index<=crc_index+1'b1;
            end
            2:if(byte_ready) begin if(byte_last) state<=0;else index<=index+1'b1;end
        endcase
    end
endmodule
