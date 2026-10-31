`timescale 1ns/1ps
// Exclusive window read coordinator. Directory ENABLE_WINDOW_TOKENS MUST be 1.
// Commands identify a CLOSED window by index+token. Holds refs through all R
// responses, pixel consumption AND result consumption; then token-check release.
// DMA, directory, iterator and output consumer require common cancellation.
module history_window_reader #(
    parameter integer FRAME_PIXELS=57600,SLOTS=64,WINDOWS=4,
    parameter integer SW=SLOTS<2 ? 1 : $clog2(SLOTS),
    parameter integer WW=WINDOWS<2 ? 1 : $clog2(WINDOWS),
    parameter [29:0] BASE_ADDR=30'h10000000
)(
    input wire clk,rst,
    input wire command_valid, output wire command_ready,
    input wire [WW-1:0] command_window,
    input wire [31:0] command_token,
    output reg [WW-1:0] query_window,
    input wire query_active,query_closed,query_truncated,query_capture_error,
    input wire [31:0] query_token,
    input wire [SLOTS-1:0] query_slots,
    input wire [255:0] query_event,
    output wire [SW-1:0] query_slot,
    input wire slot_valid,input wire [95:0] slot_meta,
    output wire rd_start,output wire [29:0] rd_base,
    input wire rd_busy,rd_done,rd_ok,
    input wire dma_valid,dma_sof,dma_last,
    input wire [15:0] dma_data, output wire dma_ready,
    output wire out_valid,out_sof,out_last,
    output wire [15:0] out_data,
    output reg [95:0] out_meta,
    output reg [31:0] out_index,
    output reg [255:0] out_event,
    input wire out_ready,
    output wire result_valid,input wire result_ready,
    output reg [2:0] result_code, //0 read success,1 handle/open,2 empty,3 descriptor,4 DMA/shape
    output wire result_ok, // read success and no known truncation/capture error; NOT coverage proof
    output reg result_truncated,result_capture_error,
    output reg [31:0] result_frames,
    output reg [31:0] result_token,
    output wire [WW-1:0] result_window,
    output wire release_valid,input wire release_ready,
    output wire [WW-1:0] release_window,output wire [31:0] release_token,
    input wire release_done,release_ok,
    output reg done,done_ok,protocol_fault
);
    localparam integer STRIDE=((FRAME_PIXELS+7)/8)*16;
    localparam IDLE=0,CHECK=1,BEGIN_ENUM=2,NEXT=3,START_DMA=4,READ=5,ACK_DESC=6,
               RESULT=7,RELEASE=8,WAIT_RELEASE=9;
    reg [3:0] state;
    reg [SLOTS-1:0] slots;
    reg owned,failed,frame_bad;
    reg [31:0] pixels;
    reg [SW-1:0] current_slot;
    wire enum_ready,desc_valid,enum_done,enum_ok,enum_fault;
    wire [SW-1:0] desc_slot;
    wire [95:0] desc_meta;
    wire [255:0] desc_event;
    wire [31:0] desc_index;
    history_descriptor_reader #(.SLOTS(SLOTS)) iterator(
        .clk(clk),.rst(rst),.start_valid(state==BEGIN_ENUM),.start_ready(enum_ready),
        .start_slots(slots),.start_event(out_event),.query_slot(query_slot),
        .query_valid(slot_valid),.query_meta(slot_meta),.out_valid(desc_valid),
        .out_ready(state==ACK_DESC),.out_slot(desc_slot),.out_meta(desc_meta),
        .out_event(desc_event),.out_index(desc_index),.done(enum_done),.ok(enum_ok),.protocol_fault(enum_fault));
    assign command_ready=!rst && state==IDLE;
    assign rd_start=!rst && state==START_DMA && !rd_busy;
    assign rd_base=BASE_ADDR+current_slot*STRIDE;
    assign out_valid=!rst && state==READ && dma_valid;
    assign out_sof=dma_sof;
    assign out_last=dma_last;
    assign out_data=dma_data;
    assign dma_ready=!rst && state==READ && out_ready;
    assign result_valid=!rst && state==RESULT;
    assign result_ok=result_code==0 && !result_truncated && !result_capture_error;
    assign result_window=query_window;
    assign release_window=query_window;
    assign release_token=result_token;
    assign release_valid=!rst && state==RELEASE;
    wire pixel_fire=out_valid && out_ready;
    wire shape_bad=pixel_fire && (pixels>=FRAME_PIXELS || dma_sof!=(pixels==0) || dma_last!=(pixels==FRAME_PIXELS-1));
    wire [32:0] count_now={1'b0,pixels}+pixel_fire;
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;query_window<=0;slots<=0;owned<=0;failed<=0;frame_bad<=0;pixels<=0;current_slot<=0;
            out_meta<=0;out_index<=0;out_event<=0;result_token<=0;result_frames<=0;result_code<=0;
            result_truncated<=0;result_capture_error<=0;done<=0;done_ok<=0;protocol_fault<=0;
        end else begin
            done<=0;
            case(state)
                IDLE:if(command_valid && command_ready) begin
                    query_window<=command_window;result_token<=command_token;
                    owned<=0;failed<=0;result_frames<=0;out_event<=0;
                    result_truncated<=0;result_capture_error<=0;result_code<=0;state<=CHECK;
                end
                CHECK:begin
                    if(!query_active || !query_closed || query_token!=result_token || result_token==0) begin
                        result_code<=1;state<=RESULT;
                    end else begin
                        owned<=1;slots<=query_slots;out_event<=query_event;
                        result_truncated<=query_truncated;result_capture_error<=query_capture_error;
                        if(query_slots==0) begin result_code<=2;state<=RESULT;end
                        else state<=BEGIN_ENUM;
                    end
                end
                BEGIN_ENUM:if(enum_ready) state<=NEXT;
                NEXT:begin
                    if(enum_done) begin
                        result_code<=!enum_ok ? 3 : failed ? 4 : 0;
                        if(!enum_ok) protocol_fault<=1;
                        state<=RESULT;
                    end else if(desc_valid) begin
                        current_slot<=desc_slot;out_meta<=desc_meta;out_index<=desc_index;
                        pixels<=0;frame_bad<=0;state<=START_DMA;
                    end
                end
                START_DMA:if(rd_start) state<=READ;
                READ:begin
                    if(pixel_fire) begin
                        if(pixels!=32'hffffffff) pixels<=pixels+1'b1;
                        if(shape_bad) begin frame_bad<=1;protocol_fault<=1;end
                    end
                    if(rd_done) begin
                        if(!rd_ok || frame_bad || shape_bad || count_now!=FRAME_PIXELS) failed<=1;
                        if(frame_bad || shape_bad || count_now!=FRAME_PIXELS) protocol_fault<=1;
                        result_frames<=result_frames+1'b1;
                        state<=ACK_DESC;
                    end
                end
                ACK_DESC:state<=NEXT;
                RESULT:if(result_valid && result_ready) begin
                    if(owned) state<=RELEASE;
                    else begin done<=1;done_ok<=0;state<=IDLE;end
                end
                RELEASE:if(release_valid && release_ready) state<=WAIT_RELEASE;
                WAIT_RELEASE:if(release_done) begin
                    done<=1;done_ok<=release_ok && result_ok;
                    if(!release_ok) protocol_fault<=1;
                    state<=IDLE;owned<=0;
                end
                default:begin protocol_fault<=1;state<=IDLE;end
            endcase
        end
    end
    // synthesis translate_off
    initial if(FRAME_PIXELS<1 || SLOTS<1 || WINDOWS<1 || BASE_ADDR[3:0]!=0 ||
        {2'b00,BASE_ADDR}+64'd1*SLOTS*STRIDE>64'h40000000) $fatal(1,"FAIL: history reader parameters");
    // synthesis translate_on
endmodule
