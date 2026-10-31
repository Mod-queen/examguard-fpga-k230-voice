`timescale 1ns/1ps
// DC,<96byte hex> LF: actual immutable result, CRC32 over first92 bytes.
module ddr3_capacity_report(
    input wire clk,rst,result_valid,output wire result_ready,
    input wire [735:0] payload,
    output wire byte_valid,byte_last,output wire [7:0] byte_data,input wire byte_ready
);
    reg [1:0] state;reg [767:0] held;reg [6:0] ci;reg [7:0] index;reg [31:0] crc;
    function automatic [31:0] step(input [31:0] old,input [7:0] b);
        reg [31:0] c;integer k;
        begin c=old^{24'd0,b};for(k=0;k<8;k=k+1) c=c[0]?(c>>1)^32'hedb88320:c>>1;step=c;end
    endfunction
    wire [3:0] nibble=held[767-(index-3)*4 -: 4];
    assign result_ready=!rst && state==0;assign byte_valid=!rst && state==2;assign byte_last=index==195;
    assign byte_data=index==0?"D":index==1?"C":index==2?",":index==195?8'h0a:nibble<10?8'h30+nibble:8'h41+nibble-10;
    always @(posedge clk) begin
        if(rst) begin state<=0;held<=0;ci<=0;index<=0;crc<=32'hffffffff;end
        else case(state)
            0:if(result_valid) begin held<={payload,32'd0};ci<=0;crc<=32'hffffffff;state<=1;end
            1:begin
                crc<=step(crc,held[767-ci*8 -: 8]);
                if(ci==91) begin held[31:0]<=~step(crc,held[767-ci*8 -: 8]);index<=0;state<=2;end
                else ci<=ci+1'b1;
            end
            2:if(byte_ready) begin if(byte_last) state<=0;else index<=index+1'b1;end
        endcase
    end
endmodule
