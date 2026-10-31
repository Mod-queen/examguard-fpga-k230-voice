`timescale 1ns/1ps
// RA,<64-byte RTC anchor record as128hex>\n. Packet-stream endpoint, no UART
// arbitration/master of its own. CRC covers bytes0..59, BE CRC bytes60..63.
module rtc_anchor_record(
    input wire clk,rst,result_valid,output wire result_ready,
    input wire [2:0] result_error,
    input wire [31:0] anchor_device,anchor_boot,anchor_sequence,
    input wire [63:0] lower_ms,upper_ms,input wire [71:0] rtc_raw,
    output wire byte_valid,byte_last,output wire [7:0] byte_data,input wire byte_ready
);
    localparam IDLE=0,CRC=1,TX=2;
    reg [1:0] state;
    reg [511:0] held;
    reg [5:0] crc_index;
    reg [7:0] index;
    reg [31:0] crc;
    reg [511:0] record_data;
    integer j;
    always @* begin
        record_data=0;
        record_data[511:464]={8'h52,8'h41,8'd1,8'd1,16'd64};
        record_data[463:448]={7'd0,(result_error==0),5'd0,result_error};
        record_data[447:416]=anchor_device;record_data[415:384]=anchor_boot;record_data[383:352]=anchor_sequence;
        record_data[351:288]=lower_ms;record_data[287:224]=upper_ms;
        for(j=0;j<9;j=j+1) record_data[223-j*8 -: 8]=rtc_raw[j*8 +: 8];
    end
    function automatic [31:0] step(input [31:0] old,input [7:0] b);
        reg [31:0] c;integer k;
        begin c=old^{24'd0,b};for(k=0;k<8;k=k+1) c=c[0]?(c>>1)^32'hedb88320:c>>1;step=c;end
    endfunction
    wire [3:0] nibble=held[511-(index-3)*4 -: 4];
    assign result_ready=!rst && state==IDLE;
    assign byte_valid=!rst && state==TX;
    assign byte_last=index==131;
    assign byte_data=index==0 ? "R" : index==1 ? "A" : index==2 ? "," : index==131 ? 8'h0a :
        nibble<10 ? 8'h30+nibble : 8'h41+nibble-10;
    always @(posedge clk) begin
        if(rst) begin state<=IDLE;held<=0;crc_index<=0;index<=0;crc<=32'hffffffff;end
        else case(state)
            IDLE:if(result_valid) begin held<=record_data;crc<=32'hffffffff;crc_index<=0;state<=CRC;end
            CRC:begin
                crc<=step(crc,held[511-crc_index*8 -: 8]);
                if(crc_index==59) begin held[31:0]<=~step(crc,held[511-crc_index*8 -: 8]);index<=0;state<=TX;end
                else crc_index<=crc_index+1'b1;
            end
            TX:if(byte_ready) begin
                if(byte_last) state<=IDLE;else index<=index+1'b1;
            end
        endcase
    end
endmodule
