`timescale 1ns/1ps
// Persistent record v1, see docs/persistent_record_contract.md.
// Serial byte CRC keeps logic bounded. encode=0 checks a record; encode=1
// builds it. Holding result through backpressure, no I2C side effects.
module eeprom_record_codec(
    input wire clk,rst,req_valid,output wire req_ready,input wire encode,
    input wire [511:0] in_body,input wire [255:0] in_commit,
    input wire [31:0] device,generation,boot,input wire [255:0] config_data,
    output reg result_valid,input wire result_ready,output wire record_ok,
    output reg [511:0] body,output reg [255:0] commit_page
);
    reg [1:0] state;
    reg encoding;
    reg [6:0] index;
    reg [31:0] crc,body_crc,commit_crc;
    function automatic [31:0] step(input [31:0] old,input [7:0] b);
        reg [31:0] c;integer i;
        begin c=old^{24'd0,b};for(i=0;i<8;i=i+1) c=c[0]?(c>>1)^32'hedb88320:c>>1;step=c;end
    endfunction
    wire [31:0] next_crc=step(crc,state==1?body[index*8 +: 8]:commit_page[index*8 +: 8]);
    assign req_ready=!rst && state==0 && !result_valid;
    assign record_ok=result_valid && body[31:0]==32'h46434745 && body[63:32]==32'h00004001 &&
        body[95:64]!=0 && body[127:96]!=0 && body[159:128]!=0 && body[479:416]==0 &&
        body[511:480]==body_crc && commit_page[31:0]==32'h4d434745 &&
        commit_page[63:32]==body[127:96] && commit_page[95:64]==~body[127:96] &&
        commit_page[127:96]==body_crc && commit_page[223:128]==0 && commit_page[255:224]==commit_crc;
    always @(posedge clk) begin
        if(rst) begin state<=0;encoding<=0;index<=0;crc<=0;body_crc<=0;commit_crc<=0;body<=0;commit_page<=0;result_valid<=0;end
        else begin
            if(result_valid && result_ready) result_valid<=0;
            case(state)
                0:if(req_valid && req_ready) begin
                    encoding<=encode;index<=0;crc<=32'hffffffff;state<=1;
                    if(encode) begin
                        body<=0;body[31:0]<=32'h46434745;body[63:32]<=32'h00004001;
                        body[95:64]<=device;body[127:96]<=generation;body[159:128]<=boot;
                        body[415:160]<=config_data;
                        commit_page<=0;commit_page[31:0]<=32'h4d434745;
                        commit_page[63:32]<=generation;commit_page[95:64]<=~generation;
                    end else begin body<=in_body;commit_page<=in_commit;end
                end
                1:begin
                    crc<=next_crc;
                    if(index==59) begin
                        body_crc<=~next_crc;
                        if(encoding) begin body[511:480]<=~next_crc;commit_page[127:96]<=~next_crc;end
                        index<=0;crc<=32'hffffffff;state<=2;
                    end else index<=index+1'b1;
                end
                2:begin
                    crc<=next_crc;
                    if(index==27) begin
                        commit_crc<=~next_crc;
                        if(encoding) commit_page[255:224]<=~next_crc;
                        state<=0;result_valid<=1;
                    end else index<=index+1'b1;
                end
            endcase
        end
    end
endmodule
