`timescale 1ns/1ps
// Observes the real register master. Never drives I2C requests or exam state.
module voice_bus_diagnostics(
    input wire clk,rst,tick_1s,boot_ready,
    input wire [31:0] device_id,boot_id,
    input wire [63:0] monotonic_ms,
    input wire [2:0] exam_stage,
    input wire scl_i,sda_i,scl_low,sda_low,link_fresh,
    input wire issue,response,write_op,
    input wire [1:0] error_code,
    input wire [7:0] clip_id,read_data,failure_byte,
    input wire [3:0] failure_stage,
    output wire byte_valid,byte_last,
    output wire [7:0] byte_data,input wire byte_ready
);
    (* ASYNC_REG="TRUE" *) reg scl_meta,scl_sync,sda_meta,sda_sync;
    reg [31:0] polls,poll_ok,nacks,timeouts,other_errors,writes,write_ok;
    reg [31:0] sequence_id;
    reg [7:0] last_poll_error,last_write_error,last_clip,last_data;
    reg [7:0] poll_stage,poll_byte,write_stage,write_byte;
    reg [7:0] startup_error,startup_stage,startup_byte;
    reg [31:0] startup_requests,startup_responses;
    reg dirty;
    wire ready;
    wire publish=boot_ready && boot_id!=0 && dirty && ready && sequence_id!=32'hffffffff;
    wire [7:0] flags={2'b0,link_fresh,boot_ready,scl_low,sda_low,scl_sync,sda_sync};
    // VD96 v1: bytes8..19 device/boot/sequence,20..27 time;
    // bytes28..55 counters;56..69 outcomes;70..77 startup counts;78..91 zero.
    wire [735:0] payload={48'h564401000060,flags,{5'd0,exam_stage},device_id,boot_id,
        sequence_id+32'd1,monotonic_ms,polls,poll_ok,nacks,timeouts,other_errors,writes,write_ok,
        last_poll_error,last_write_error,last_clip,last_data,poll_stage,poll_byte,write_stage,write_byte,
        startup_error,startup_stage,startup_byte,8'd0,8'hd0,8'he0,
        startup_requests,startup_responses,112'd0};
    function [31:0] inc(input [31:0] value);
        inc=(value==32'hffffffff) ? value : value+1'b1;
    endfunction
    always @(posedge clk) begin
        if(rst) begin
            scl_meta<=1;scl_sync<=1;sda_meta<=1;sda_sync<=1;
            polls<=0;poll_ok<=0;nacks<=0;timeouts<=0;other_errors<=0;writes<=0;write_ok<=0;
            sequence_id<=0;dirty<=1;last_poll_error<=8'hff;last_write_error<=8'hff;
            last_clip<=0;last_data<=0;poll_stage<=0;poll_byte<=0;write_stage<=0;write_byte<=0;
            startup_error<=8'hff;startup_stage<=0;startup_byte<=0;startup_requests<=0;startup_responses<=0;
        end else begin
            scl_meta<=scl_i;scl_sync<=scl_meta;sda_meta<=sda_i;sda_sync<=sda_meta;
            if(publish) begin dirty<=0;sequence_id<=sequence_id+1'b1;end
            if(tick_1s) dirty<=1;
            if(issue) begin
                if(write_op) begin
                    writes<=inc(writes);last_clip<=clip_id;
                    if(clip_id==8'h21) startup_requests<=inc(startup_requests);
                end else polls<=inc(polls);
            end
            if(response) begin
                if(error_code==1) nacks<=inc(nacks);
                if(error_code==2) timeouts<=inc(timeouts);
                if(error_code==3) other_errors<=inc(other_errors);
                if(write_op) begin
                    last_write_error<={6'd0,error_code};
                    write_stage<={4'd0,failure_stage};write_byte<=failure_byte;
                    if(error_code==0) write_ok<=inc(write_ok);
                    if(clip_id==8'h21) begin
                        startup_error<={6'd0,error_code};startup_stage<={4'd0,failure_stage};
                        startup_byte<=failure_byte;startup_responses<=inc(startup_responses);
                    end
                end else begin
                    last_poll_error<={6'd0,error_code};poll_stage<={4'd0,failure_stage};poll_byte<=failure_byte;
                    if(error_code==0) begin poll_ok<=inc(poll_ok);last_data<=read_data;end
                end
            end
        end
    end
    voice_status_record #(.RECORD_SECOND("D")) record(.*,.status_valid(publish),.status_ready(ready),.payload(payload));
endmodule
