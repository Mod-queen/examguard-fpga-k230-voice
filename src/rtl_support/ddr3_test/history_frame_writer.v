`timescale 1ns/1ps
// UI-domain coordinator, exclusive owner of directory reserve/finish/seal and
// DMA write commands. Commands form ONE ordered stream: frame or seal fence.
// A frame command precedes its pixels; a fence may follow only all frames/drop
// decisions at or before its time. Never connect wall-clock time as a fence.
// All users, directory, DMA and AXI slave MUST share cancellation reset.
module history_frame_writer #(
    parameter integer FRAME_PIXELS=57600,SLOTS=64,
    parameter integer SW=SLOTS<2 ? 1 : $clog2(SLOTS),
    parameter [29:0] BASE_ADDR=30'h10000000
)(
    input wire clk,rst,
    input wire command_valid, output wire command_ready,
    input wire command_fence,
    input wire [95:0] command_meta, // frame_id/time, fence uses only low64
    input wire pixel_valid,pixel_last,
    input wire [15:0] pixel_data,
    output wire pixel_ready,
    output wire reserve_valid, input wire reserve_ready,
    input wire grant_valid, output wire grant_ready,
    input wire grant_ok, input wire [SW-1:0] grant_slot,
    input wire [31:0] grant_token,
    output wire finish_valid, input wire finish_ready,
    output reg [SW-1:0] finish_slot,
    output reg [31:0] finish_token,
    output wire finish_ok, output reg [95:0] finish_meta,
    output wire seal_valid, input wire seal_ready,
    output reg [63:0] seal_time,
    output wire wr_start, output wire [29:0] wr_base,
    input wire wr_busy,wr_done,wr_ok,
    output wire dma_valid,dma_last,
    output wire [15:0] dma_data, input wire dma_ready,
    output wire result_valid, input wire result_ready,
    output wire [95:0] result_meta,
    output reg [2:0] result_code, // 0 commit,1 capacity,2 DMA,3 shape,4 time
    output reg fence_done,fence_ok,
    output reg protocol_fault,
    output reg [31:0] frames_committed,frames_dropped
);
    localparam integer STRIDE=((FRAME_PIXELS+7)/8)*16;
    localparam IDLE=0,RESERVE=1,GRANT=2,START=3,PIXELS=4,
               WAIT_DMA=5,DRAIN=6,FINISH=7,RESULT=8,SEAL=9,DROP=10;
    reg [3:0] state;
    reg [31:0] pixel_index;
    reg malformed,need_drain,dma_success;
    reg have_frame,have_seal;
    reg [63:0] last_frame,sealed;
    wire time_valid=(!have_frame || command_meta[63:0]>last_frame) &&
                    (!have_seal || command_meta[63:0]>sealed);
    assign command_ready=!rst && state==IDLE;
    assign reserve_valid=!rst && state==RESERVE;
    assign grant_ready=!rst && state==GRANT;
    assign wr_start=!rst && state==START && !wr_busy;
    assign wr_base=BASE_ADDR+finish_slot*STRIDE;
    assign dma_valid=!rst && state==PIXELS && pixel_valid;
    assign dma_data=pixel_data;
    assign dma_last=pixel_last; // keep malformed LAST visible to the real DMA
    assign pixel_ready=!rst && ((state==PIXELS && dma_ready) || state==DROP || state==DRAIN);
    assign finish_valid=!rst && state==FINISH;
    assign finish_ok=dma_success && !malformed;
    assign seal_valid=!rst && state==SEAL;
    assign result_valid=!rst && state==RESULT;
    assign result_meta=finish_meta;
    function [31:0] inc_sat;
        input [31:0] n;
        begin inc_sat=n==32'hffffffff ? n : n+1'b1;end
    endfunction
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;pixel_index<=0;malformed<=0;need_drain<=0;dma_success<=0;
            finish_slot<=0;finish_token<=0;finish_meta<=0;seal_time<=0;
            have_frame<=0;have_seal<=0;last_frame<=0;sealed<=0;
            result_code<=0;fence_done<=0;fence_ok<=0;protocol_fault<=0;
            frames_committed<=0;frames_dropped<=0;
        end else begin
            fence_done<=0;
            case(state)
                IDLE: if(command_valid && command_ready) begin
                    if(command_fence) begin
                        if((have_seal && command_meta[63:0]<sealed) ||
                           (have_frame && command_meta[63:0]<last_frame)) begin
                            protocol_fault<=1;fence_done<=1;fence_ok<=0;
                        end else begin seal_time<=command_meta[63:0];state<=SEAL;end
                    end else begin
                        finish_meta<=command_meta;pixel_index<=0;malformed<=0;need_drain<=0;dma_success<=0;
                        if(!time_valid) begin protocol_fault<=1;result_code<=4;state<=DROP;end
                        else begin
                            have_frame<=1;last_frame<=command_meta[63:0];state<=RESERVE;
                        end
                    end
                end
                RESERVE: if(reserve_valid && reserve_ready) state<=GRANT;
                GRANT: if(grant_valid && grant_ready) begin
                    if(grant_ok) begin finish_slot<=grant_slot;finish_token<=grant_token;state<=START;end
                    else begin result_code<=1;state<=DROP;end
                end
                START: if(wr_start) state<=PIXELS;
                PIXELS: if(pixel_valid && pixel_ready) begin
                    if(pixel_last!=(pixel_index==FRAME_PIXELS-1)) begin malformed<=1;protocol_fault<=1;end
                    if(pixel_last || pixel_index==FRAME_PIXELS-1) begin
                        need_drain<=!pixel_last;state<=WAIT_DMA;
                    end else pixel_index<=pixel_index+1'b1;
                end
                WAIT_DMA: if(wr_done) begin
                    dma_success<=wr_ok;
                    result_code<=malformed ? 3 : wr_ok ? 0 : 2;
                    if(need_drain) state<=DRAIN;else state<=FINISH;
                end
                DRAIN: if(pixel_valid && pixel_ready && pixel_last) state<=FINISH;
                FINISH: if(finish_valid && finish_ready) begin
                    // Exclusive ownership and time checks above establish the
                    // directory's acceptance preconditions. No other writer or
                    // external seal source may drive it in this configuration.
                    if(finish_ok) frames_committed<=inc_sat(frames_committed);
                    else frames_dropped<=inc_sat(frames_dropped);
                    state<=RESULT;
                end
                DROP: if(pixel_valid && pixel_ready && pixel_last) begin
                    frames_dropped<=inc_sat(frames_dropped);state<=RESULT;
                end
                RESULT: if(result_valid && result_ready) state<=IDLE;
                SEAL: if(seal_valid && seal_ready) begin
                    have_seal<=1;sealed<=seal_time;fence_done<=1;fence_ok<=1;state<=IDLE;
                end
                default: begin protocol_fault<=1;state<=IDLE;end
            endcase
        end
    end
    // synthesis translate_off
    initial if(FRAME_PIXELS<1 || SLOTS<1 || BASE_ADDR[3:0]!=0 ||
               {2'b00,BASE_ADDR}+64'd1*SLOTS*STRIDE>64'h40000000)
        $fatal(1,"FAIL: history writer address/size parameters");
    // synthesis translate_on
endmodule
