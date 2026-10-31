`timescale 1ns/1ps
// CRC-validated command -> boot-bound operation -> one MR result. Duplicate of
// most recent identical request replays its immutable result; token collision
// rejected. Not an unlimited replay cache, not authenticated transport.
module maintenance_endpoint(
    input wire clk,rst,rx_valid,input wire [7:0] rx_data,
    input wire [31:0] device_id,boot_id,generation,input wire boot_done,
    input wire config_known,input wire [255:0] active_config,
    output wire request_valid,input wire request_ready,output wire [1:0] opcode,
    output reg [255:0] proposed_config,output reg [55:0] calendar_data,
    input wire result_valid,output wire result_ready,
    input wire [1:0] result_opcode,result_recovery_error,
    input wire [3:0] result_error,result_detail,result_store_error,
    input wire result_write_attempted,input wire [71:0] result_snapshot,
    output wire byte_valid,byte_last,output wire [7:0] byte_data,input wire byte_ready,
    output wire command_pending,output wire [31:0] rejected_lines
);
    reg [2:0] state;
    wire command_valid;wire [511:0] command_data;
    reg [511:0] held_command,last_command;reg last_valid;
    reg [735:0] response,last_response;
    reg [31:0] token;reg [7:0] operation;
    reg [15:0] utc_offset;
    wire record_ready;
    maintenance_command_rx receiver(.clk(clk),.rst(rst),.rx_valid(rx_valid),.rx_data(rx_data),
        .command_valid(command_valid),.command_ready(state==0 && boot_done),.command_data(command_data),.rejected_lines(rejected_lines));
    assign request_valid=!rst && state==1;
    assign opcode=operation[1:0];
    assign result_ready=!rst && state==2;
    assign command_pending=command_valid || state!=0;
    maintenance_record record_inst(.clk(clk),.rst(rst),.result_valid(state==3),.result_ready(record_ready),
        .payload(response),.byte_valid(byte_valid),.byte_last(byte_last),.byte_data(byte_data),.byte_ready(byte_ready));
    function automatic [735:0] make_response(input [7:0] op,err,input [31:0] id,
        input [3:0] detail,store_error,input [1:0] recovery,input attempted,input [71:0] rtc,input [15:0] offset);
        reg [735:0] r;integer k;
        begin
            r=0;r[735:688]=48'h4d5201010060;r[687:680]=op;r[679:672]=err;
            r[671:640]=id;r[639:608]=device_id;r[607:576]=boot_id;r[575:544]=generation;
            r[543:536]={7'd0,config_known};r[535:528]={4'd0,detail};r[527:520]={4'd0,store_error};
            r[519:512]={6'd0,recovery};r[511:504]={7'd0,attempted};
            for(k=0;k<32;k=k+1) r[479-k*8 -: 8]=active_config[k*8+:8];
            for(k=0;k<9;k=k+1) r[223-k*8 -: 8]=rtc[k*8+:8];
            r[151:136]=offset;make_response=r;
        end
    endfunction
    wire [7:0] cmd_op=command_data[463:456];wire [31:0] cmd_id=command_data[447:416];
    reg [255:0] decoded_config;reg [55:0] decoded_calendar;integer j;
    always @* begin
        decoded_config=0;decoded_calendar=0;
        for(j=0;j<32;j=j+1) decoded_config[j*8+:8]=command_data[351-j*8 -: 8];
        for(j=0;j<7;j=j+1) decoded_calendar[j*8+:8]=command_data[351-j*8 -: 8];
    end
    wire signed [15:0] cmd_offset=command_data[295:280];
    wire malformed=command_data[455:448]!=0 || cmd_id==0 || command_data[95:32]!=0 || cmd_op>2 ||
        (cmd_op==0 && command_data[351:96]!=0) ||
        (cmd_op==2 && (command_data[279:96]!=0 || cmd_offset < -16'sd720 || cmd_offset > 16'sd840));
    always @(posedge clk) begin
        if(rst) begin state<=0;held_command<=0;last_command<=0;last_valid<=0;response<=0;last_response<=0;
            token<=0;operation<=0;utc_offset<=16'h7fff;proposed_config<=0;calendar_data<=0;end
        else case(state)
            0:if(command_valid && boot_done) begin
                if(command_data[415:384]!=device_id || command_data[383:352]!=boot_id)
                    response<=make_response(cmd_op,8'd6,cmd_id,0,0,0,0,0,16'h7fff);
                else if(last_valid && cmd_id==last_command[447:416]) begin
                    if(command_data==last_command) response<=last_response;
                    else response<=make_response(cmd_op,8'd7,cmd_id,0,0,0,0,0,16'h7fff);
                end else if(last_valid && cmd_id<last_command[447:416]) begin
                    response<=make_response(cmd_op,8'd8,cmd_id,0,0,0,0,0,16'h7fff);
                end else if(malformed) response<=make_response(cmd_op,8'd5,cmd_id,0,0,0,0,0,16'h7fff);
                else begin
                    held_command<=command_data;token<=cmd_id;operation<=cmd_op;
                    proposed_config<=decoded_config;calendar_data<=decoded_calendar;
                    utc_offset<=cmd_op==2?cmd_offset:16'h7fff;
                end
                if(command_data[415:384]!=device_id || command_data[383:352]!=boot_id ||
                    (last_valid && cmd_id<=last_command[447:416]) || malformed) state<=3;
                else state<=1;
            end
            1:if(request_ready) state<=2;
            2:if(result_valid) begin
                response<=make_response(operation,result_opcode!=operation[1:0]?8'd9:{4'd0,result_error},token,result_detail,result_store_error,
                    result_recovery_error,result_write_attempted,result_snapshot,utc_offset);
                last_response<=make_response(operation,result_opcode!=operation[1:0]?8'd9:{4'd0,result_error},token,result_detail,result_store_error,
                    result_recovery_error,result_write_attempted,result_snapshot,utc_offset);
                last_command<=held_command;last_valid<=1;state<=3;
            end
            3:if(record_ready) state<=4;
            4:if(byte_valid && byte_ready && byte_last) state<=0;
            default:state<=0;
        endcase
    end
endmodule
