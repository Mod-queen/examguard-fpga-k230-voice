`timescale 1ns/1ps
// BM64B: header, valid/switch flags, device/boot/seq/seat/monotonic64,
// 4x16-bit raw ADC (TEMP/INT/AUX/BRAM), sequence32, age32, reserved, CRC.
module board_monitor_record #(
    parameter integer PERIOD_CYCLES=50000000,STALE_CYCLES=50000000
)(
    input wire clk,rst,input wire [96:0] monitor,input wire monitor_valid,
    input wire [31:0] device_id,boot_id,seat_id,input wire [63:0] monotonic_ms,
    input wire straps_valid,input wire [7:0] switches,
    output wire byte_valid,byte_last,output wire [7:0] byte_data,input wire byte_ready
);
    reg [31:0] timer,sequence_id,age,last_sequence;
    reg seen;wire changed=monitor_valid && monitor[96] && (!seen || monitor[95:64]!=last_sequence);
    reg [511:0] record_data;integer k;
    always @* begin
        record_data=0;
        record_data[511:464]=48'h424d01010040;
        record_data[463:456]={6'd0,straps_valid,(seen && monitor_valid && monitor[96] && age<=STALE_CYCLES)};
        record_data[455:448]=switches;record_data[447:416]=device_id;record_data[415:384]=boot_id;
        record_data[383:352]=sequence_id;record_data[351:320]=seat_id;record_data[319:256]=monotonic_ms;
        for(k=0;k<4;k=k+1) record_data[255-k*16 -: 16]=monitor[k*16+:16];
        record_data[191:160]=monitor[95:64];record_data[159:128]=age;
    end
    reg [1:0] state;reg [511:0] held;reg [5:0] ci;reg [7:0] index;reg [31:0] crc;
    function automatic [31:0] step(input [31:0] old,input [7:0] b);
        reg [31:0] c;integer j;
        begin c=old^{24'd0,b};for(j=0;j<8;j=j+1) c=c[0]?(c>>1)^32'hedb88320:c>>1;step=c;end
    endfunction
    wire [3:0] n=held[511-(index-3)*4 -: 4];
    assign byte_valid=!rst && state==2;assign byte_last=index==131;
    assign byte_data=index==0?"B":index==1?"M":index==2?",":index==131?8'h0a:n<10?8'h30+n:8'h41+n-10;
    always @(posedge clk) begin
        if(rst) begin timer<=0;sequence_id<=1;age<=32'hffffffff;last_sequence<=0;seen<=0;
            state<=0;held<=0;ci<=0;index<=0;crc<=32'hffffffff;end
        else begin
            if(changed) begin age<=0;last_sequence<=monitor[95:64];seen<=1;end
            else if(age!=32'hffffffff) age<=age+1'b1;
            if(timer!=PERIOD_CYCLES-1) timer<=timer+1'b1;
            case(state)
                0:if(timer==PERIOD_CYCLES-1 && boot_id!=0) begin held<=record_data;ci<=0;crc<=32'hffffffff;state<=1;timer<=0;end
                1:begin
                    crc<=step(crc,held[511-ci*8 -: 8]);
                    if(ci==59) begin held[31:0]<=~step(crc,held[511-ci*8 -: 8]);index<=0;state<=2;end
                    else ci<=ci+1'b1;
                end
                2:if(byte_ready) begin
                    if(byte_last) begin state<=0;if(sequence_id!=32'hffffffff) sequence_id<=sequence_id+1'b1;end
                    else index<=index+1'b1;
                end
            endcase
        end
    end
endmodule
