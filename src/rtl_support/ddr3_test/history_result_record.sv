`timescale 1ns/1ps
// Fixed 128-byte history window result record, transport agnostic.
// Header: "HR", version1, kind1(window result), length128, flags, reserved.
// The whole merged scheduler result is preserved (transaction/window/token/code/
// frames/gap count+unknown+range/first-last gap meta+reason) and protected by
// standard reflected CRC32 (init FFFFFFFF, final invert, poly EDB88320).
// result_ready is asserted only in IDLE, so the producer must hold result pins.
module history_result_record #(
    parameter integer WINDOWS=4,
    parameter integer WW=WINDOWS<2 ? 1 : $clog2(WINDOWS)
)(
    input wire clk,rst,
    input wire result_valid,output wire result_ready,
    input wire [WW-1:0] result_window,input wire [31:0] result_token,
    input wire [2:0] result_code,
    input wire result_ok,result_truncated,result_capture_error,
    input wire [31:0] result_frames,result_gap_count,
    input wire result_gap_unknown,result_gap_bad_range,result_coverage_ok,
    input wire [63:0] result_lower,result_upper,
    input wire [95:0] result_gap_first_meta,result_gap_last_meta,
    input wire [7:0] result_gap_first_reason,result_gap_last_reason,
    input wire [255:0] result_event,
    output wire tx_valid,tx_last,
    output wire [7:0] tx_data,
    input wire tx_ready,
    output reg protocol_fault,
    output reg [31:0] records_sent
);
    localparam IDLE=0,SEND=1,CRC=2;
    reg [1:0] state;
    reg [6:0] pos;
    reg [1:0] crc_pos;
    reg [31:0] crc_reg;
    reg [991:0] record; // 124 bytes
    wire [7:0] flags={2'b00,result_coverage_ok,result_gap_bad_range,
                      result_gap_unknown,result_capture_error,result_truncated,result_ok};
    function [31:0] crc32_byte;
        input [31:0] crc;
        input [7:0] data;
        reg [31:0] c;
        integer i;
        begin
            c=crc;
            for(i=0;i<8;i=i+1) begin
                if(c[0]^data[i]) c=(c>>1)^32'hedb88320;
                else c=c>>1;
            end
            crc32_byte=c;
        end
    endfunction
    function [31:0] inc_sat;
        input [31:0] n;
        begin inc_sat=n==32'hffffffff ? n : n+1'b1;end
    endfunction
    function [7:0] crc_byte_out;
        input [1:0] p;
        input [31:0] c;
        begin
            case(p)
                0:crc_byte_out=~c[31:24];
                1:crc_byte_out=~c[23:16];
                2:crc_byte_out=~c[15:8];
                default:crc_byte_out=~c[7:0];
            endcase
        end
    endfunction
    wire [7:0] record_byte=record[991-pos*8 -: 8];
    wire crc_fire=tx_valid && tx_ready && state==CRC;
    assign result_ready=!rst && state==IDLE;
    assign tx_valid=!rst && state!=IDLE;
    assign tx_last=!rst && state==CRC && crc_pos==3;
    assign tx_data=state==SEND ? record_byte : crc_byte_out(crc_pos,crc_reg);
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;pos<=0;crc_pos<=0;crc_reg<=32'hffffffff;record<=0;
            protocol_fault<=0;records_sent<=0;
        end else case(state)
            IDLE:if(result_valid && result_ready) begin
                record<={8'h48,8'h52,8'd1,8'd1,16'd128,flags,8'd0,
                    result_event,
                    {{(32-WW){1'b0}},result_window},result_token,
                    {{29{1'b0}},result_code},result_frames,result_gap_count,
                    result_lower,result_upper,
                    result_gap_first_meta,result_gap_last_meta,
                    result_gap_first_reason,result_gap_last_reason,
                    {22{8'd0}}};
                pos<=0;crc_pos<=0;crc_reg<=32'hffffffff;state<=SEND;
            end
            SEND:if(tx_ready) begin
                crc_reg<=crc32_byte(crc_reg,record_byte);
                if(pos==7'd123) begin state<=CRC;crc_pos<=0;end
                else pos<=pos+1'b1;
            end
            CRC:if(crc_fire) begin
                if(crc_pos==3) begin
                    records_sent<=inc_sat(records_sent);state<=IDLE;
                end else crc_pos<=crc_pos+1'b1;
            end
            default:begin protocol_fault<=1;state<=IDLE;end
        endcase
    end
    // synthesis translate_off
    initial if(WINDOWS<1 || WW>32) $fatal(1,"FAIL: history result record parameters");
    // synthesis translate_on
endmodule
