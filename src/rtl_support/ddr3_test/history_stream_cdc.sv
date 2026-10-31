`timescale 1ns/1ps
// Commands and pixels occupy ONE FIFO, so a fence cannot overtake frame data.
// Synchronous interface resets must come from a common cancellation barrier.
// tag0={kind2,meta96,reason8}; tag1={padding89,LAST1,pixel16}.
// Fixed107bit word trades storage for a simple auditable ordering contract.
module history_stream_cdc #(parameter integer DEPTH=64)(
    input wire src_clk,src_rst,dst_clk,dst_rst,
    input wire command_valid,output wire command_ready,
    input wire [1:0] command_kind,input wire [95:0] command_meta,input wire [7:0] command_reason,
    input wire pixel_valid,pixel_last,input wire [15:0] pixel_data,output wire pixel_ready,
    output wire dst_command_valid,input wire dst_command_ready,
    output wire [1:0] dst_command_kind,output wire [95:0] dst_command_meta,output wire [7:0] dst_command_reason,
    output wire dst_pixel_valid,dst_pixel_last,output wire [15:0] dst_pixel_data,input wire dst_pixel_ready,
    output reg src_halted,dst_halted
);
    reg sending_pixels,receiving_pixels;
    wire full,empty;
    wire [106:0] rdata;
    reg [106:0] held;
    reg held_valid;
    wire bad_kind=command_kind==3;
    assign command_ready=!src_rst && !src_halted && !sending_pixels && !full;
    assign pixel_ready=!src_rst && !src_halted && sending_pixels && !full;
    wire cmd_fire=command_valid && command_ready;
    wire pix_fire=pixel_valid && pixel_ready;
    wire write_word=(cmd_fire && !bad_kind) || pix_fire;
    wire [106:0] wdata=sending_pixels ? {1'b1,89'd0,pixel_last,pixel_data} : {1'b0,command_kind,command_meta,command_reason};
    wire malformed=held_valid && (held[106]!=receiving_pixels ||
        (!held[106] && held[105:104]==3) || (held[106] && held[105:17]!=0));
    assign dst_command_valid=!dst_rst && !dst_halted && held_valid && !receiving_pixels && !malformed;
    assign dst_pixel_valid=!dst_rst && !dst_halted && held_valid && receiving_pixels && !malformed;
    assign dst_command_kind=held[105:104];
    assign dst_command_meta=held[103:8];
    assign dst_command_reason=held[7:0];
    assign dst_pixel_data=held[15:0];
    assign dst_pixel_last=held[16];
    wire consume=(dst_command_valid && dst_command_ready) || (dst_pixel_valid && dst_pixel_ready);
    wire take=!dst_rst && !dst_halted && !empty && (!held_valid || consume);
    // Preserve explicit holding flops and the reviewed asynchronous LUTRAM
    // read timing model; prevent BRAM absorption of the held-data register.
    async_fifo #(.DATA_WIDTH(107),.DEPTH(DEPTH),.RAM_STYLE("distributed")) fifo(
        .wclk(src_clk),.wrst_n(!src_rst),.winc(write_word),.wdata(wdata),.wfull(full),
        .rclk(dst_clk),.rrst_n(!dst_rst),.rinc(take),.rdata(rdata),.rempty(empty));
    always @(posedge src_clk) begin
        if(src_rst) begin sending_pixels<=0;src_halted<=0;end
        else if(!src_halted) begin
            if(cmd_fire) begin
                if(bad_kind) src_halted<=1;
                else if(command_kind==0) sending_pixels<=1;
            end
            if(pix_fire && pixel_last) sending_pixels<=0;
        end
    end
    always @(posedge dst_clk) begin
        if(dst_rst) begin receiving_pixels<=0;dst_halted<=0;held_valid<=0;held<=0;end
        else if(!dst_halted) begin
            if(malformed) dst_halted<=1;
            if(dst_command_valid && dst_command_ready && dst_command_kind==0) receiving_pixels<=1;
            if(dst_pixel_valid && dst_pixel_ready && dst_pixel_last) receiving_pixels<=0;
            if(!held_valid || consume) begin
                held_valid<=take;
                if(take) held<=rdata;
            end
        end
    end
endmodule
