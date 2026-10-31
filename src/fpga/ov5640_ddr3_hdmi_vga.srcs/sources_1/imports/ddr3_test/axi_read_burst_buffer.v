`timescale 1ns/1ps

// One complete read-burst response buffer. Does not issue addresses itself:
// ar_open gates upstream ARVALID/READY, ar_fire is the downstream handshake.
// Releases shared arbiter ownership at slave RLAST independently of a slow
// RGB565 unpacker. Upstream gets original data/ID/RESP/LAST, held under stall.
// MAX_BEATS must cover every issued ARLEN+1. Normal evidence DMA uses <=32.
// A malformed overlong response drains without memory overwrite and halts until
// common reset; no fabricated RLAST/OKAY. System watchdog handles lost LAST.
module axi_read_burst_buffer #(
    parameter integer MAX_BEATS=32,
    parameter integer INDEX_W=MAX_BEATS<2 ? 1 : $clog2(MAX_BEATS)
)(
    input wire clk,rst,ar_fire,
    output wire ar_open,
    input wire [127:0] in_data,
    input wire [3:0] in_id,
    input wire [1:0] in_resp,
    input wire in_last,in_valid,
    output wire in_ready,
    output wire [127:0] out_data,
    output wire [3:0] out_id,
    output wire [1:0] out_resp,
    output wire out_last,out_valid,
    input wire out_ready,
    output reg overflow_fault
);
    localparam [1:0] IDLE=0,CAPTURE=1,PUBLISH=2,HALT=3;
    reg [1:0] state;
    reg [INDEX_W:0] count;
    reg [INDEX_W-1:0] index;
    (* ram_style="distributed" *) reg [134:0] data_mem[0:MAX_BEATS-1];
    assign ar_open=!rst && state==IDLE;
    assign in_ready=!rst && state==CAPTURE;
    assign out_valid=!rst && state==PUBLISH;
    assign {out_id,out_resp,out_last,out_data}=data_mem[index];
    always @(posedge clk) begin
        if(in_valid && in_ready && count<MAX_BEATS) data_mem[count]<= {in_id,in_resp,in_last,in_data};
        if(rst) begin state<=IDLE;count<=0;index<=0;overflow_fault<=0;end
        else begin
            if(ar_fire && ar_open) begin state<=CAPTURE;count<=0;index<=0;end
            if(in_valid && in_ready) begin
                if(count<MAX_BEATS) count<=count+1'b1;
                else overflow_fault<=1;
                if(in_last) begin
                    if(count>=MAX_BEATS || overflow_fault) state<=HALT;
                    else begin state<=PUBLISH;index<=0;end
                end
            end
            if(out_valid && out_ready) begin
                if(out_last) state<=IDLE;else index<=index+1'b1;
            end
        end
    end
    // synthesis translate_off
    initial if(MAX_BEATS<1 || MAX_BEATS>256) $fatal(1,"FAIL: read buffer capacity");
    // synthesis translate_on
endmodule
