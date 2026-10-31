`timescale 1ns/1ps
// Sampling-domain non-stallable producer. Every selected source frame reserves
// a decision queue entry at START, before pixels can be accepted. Entries leave
// in START order as FRAME/DROP, optional pixels, then FENCE at that source time.
// Missing/invalid time or full decision queue halts the epoch; caller MUST
// cancel source, CDC, ingress, store/AXI together. No silent loss then later seal.
// FRAME_PIXELS counts already-selected samples, not DVP bytes or display pixels.
module history_capture_source #(
    parameter integer FRAME_PIXELS=57600,DEPTH=16,
    parameter integer IW=FRAME_PIXELS<2?1:$clog2(FRAME_PIXELS),
    parameter integer QW=DEPTH<2?1:$clog2(DEPTH),CW=$clog2(DEPTH+1)
)(
    input wire clk,rst,
    input wire frame_start,frame_end,enable,time_valid,
    input wire [95:0] in_meta,
    input wire in_valid,in_last,input wire [IW-1:0] in_index,
    input wire [15:0] in_data,
    output wire command_valid,input wire command_ready,
    output wire [1:0] command_kind,output wire [95:0] command_meta,
    output wire [7:0] command_reason,
    output wire pixel_valid,input wire pixel_ready,
    output wire pixel_last,output wire [15:0] pixel_data,
    output reg halted,output reg [2:0] halt_reason, //1 queue full,2 unknown time,3 order
    output wire [CW-1:0] occupancy,
    output wire [1:0] banks_occupied,
    output reg [31:0] frames_seen,frames_published,frames_dropped,decisions_sent
);
    localparam CMD=0,DATA=1,FENCE=2;
    reg [1:0] state;
    reg [QW-1:0] wr_ptr,rd_ptr,capture_entry;
    reg [CW-1:0] count;
    reg [DEPTH-1:0] resolved;
    reg [95:0] metadata[0:DEPTH-1];
    reg kinds[0:DEPTH-1],bank_id[0:DEPTH-1]; // kinds: 0 FRAME,1 DROP
    reg [7:0] reasons[0:DEPTH-1];
    (* ram_style="block" *) reg [15:0] bank0[0:FRAME_PIXELS-1],bank1[0:FRAME_PIXELS-1];
    reg [1:0] busy;
    reg capturing,capture_bank,have_time;
    reg [IW-1:0] capture_index,read_index;
    reg [63:0] last_time;
    reg pending,held_valid;
    reg [15:0] read0,read1,held_data;
    wire head_ready=count!=0 && resolved[rd_ptr];
    assign command_valid=!rst && !halted && head_ready && (state==CMD || state==FENCE);
    assign command_kind=state==FENCE ? 2'd2 : {1'b0,kinds[rd_ptr]};
    assign command_meta=head_ready ? metadata[rd_ptr] : 96'd0;
    assign command_reason=head_ready && state==CMD ? reasons[rd_ptr] : 8'd0;
    assign pixel_valid=!rst && !halted && state==DATA && held_valid;
    assign pixel_last=read_index==FRAME_PIXELS-1;
    assign pixel_data=held_data;
    assign occupancy=count;
    assign banks_occupied={1'b0,busy[0]}+{1'b0,busy[1]};
    wire pop=command_valid && command_ready && state==FENCE;
    wire bad_start=frame_start && (!time_valid || (have_time && in_meta[63:0]<=last_time) || count==DEPTH);
    wire push=frame_start && !bad_start && !halted && !rst;
    wire release_bank=pixel_valid && pixel_ready && pixel_last;
    wire read_issue=!rst && !halted && state==DATA && !pending && !held_valid;
    reg next_capturing,next_bank,do_write,publish,fail;
    reg [QW-1:0] next_entry;
    reg [IW-1:0] next_index,write_index;
    reg [7:0] fail_reason;
    wire allocate=push && enable && busy!=2'b11;
    wire selected_bank=busy[0];
    always @* begin
        next_capturing=capturing;next_bank=capture_bank;next_entry=capture_entry;
        next_index=capture_index;write_index=capture_index;
        do_write=0;publish=0;fail=0;fail_reason=0;
        if(push) begin
            next_capturing=allocate;next_bank=selected_bank;next_entry=wr_ptr;next_index=0;
        end
        if(next_capturing) begin
            write_index=next_index;
            if(in_valid) begin
                if(in_index!=next_index || in_last!=(next_index==FRAME_PIXELS-1)) begin
                    fail=1;fail_reason=3;next_capturing=0;
                end else begin
                    do_write=1;
                    if(in_last) begin publish=1;next_capturing=0;end
                    else next_index=next_index+1'b1;
                end
            end
            if(frame_end && next_capturing) begin fail=1;fail_reason=5;next_capturing=0;end
        end
    end
    function [QW-1:0] advance(input [QW-1:0] p);
        advance=p==DEPTH-1 ? 0 : p+1'b1;
    endfunction
    function [31:0] add_sat(input [31:0] n,input [1:0] amount);
        reg [32:0] sum;
        begin sum={1'b0,n}+amount;add_sat=sum[32] ? 32'hffffffff : sum[31:0];end
    endfunction
    // Memory never reset; ownership and head resolution gate all reads.
    always @(posedge clk) begin
        if(!rst && !halted && !bad_start && do_write) begin
            if(next_bank) bank1[write_index]<=in_data;else bank0[write_index]<=in_data;
        end
        if(read_issue) begin read0<=bank0[read_index];read1<=bank1[read_index];end
    end
    always @(posedge clk) begin
        if(rst) begin
            state<=CMD;wr_ptr<=0;rd_ptr<=0;count<=0;resolved<=0;busy<=0;
            capturing<=0;capture_bank<=0;capture_entry<=0;capture_index<=0;have_time<=0;last_time<=0;
            pending<=0;held_valid<=0;held_data<=0;read_index<=0;
            halted<=0;halt_reason<=0;frames_seen<=0;frames_published<=0;frames_dropped<=0;decisions_sent<=0;
        end else if(!halted) begin
            if(frame_start) frames_seen<=add_sat(frames_seen,1);
            if(bad_start) begin
                halted<=1;halt_reason<=!time_valid ? 2 : (have_time && in_meta[63:0]<=last_time) ? 3 : 1;
            end else begin
                count<=count+push-pop;
                capturing<=next_capturing;capture_bank<=next_bank;capture_entry<=next_entry;capture_index<=next_index;
                if(pop) begin resolved[rd_ptr]<=0;rd_ptr<=advance(rd_ptr);state<=CMD;decisions_sent<=add_sat(decisions_sent,1);end
                if(release_bank) busy[bank_id[rd_ptr]]<=0;
                if(push) begin
                    wr_ptr<=advance(wr_ptr);metadata[wr_ptr]<=in_meta;
                    have_time<=1;last_time<=in_meta[63:0];
                    resolved[wr_ptr]<=!allocate;kinds[wr_ptr]<=!allocate;bank_id[wr_ptr]<=selected_bank;
                    reasons[wr_ptr]<=!enable ? 1 : !allocate ? 2 : 0;
                    if(capturing) begin
                        resolved[capture_entry]<=1;kinds[capture_entry]<=1;reasons[capture_entry]<=4;busy[capture_bank]<=0;
                    end
                    if(allocate) busy[selected_bank]<=1;
                end
                if(publish) begin resolved[next_entry]<=1;frames_published<=add_sat(frames_published,1);end
                if(fail) begin
                    resolved[next_entry]<=1;kinds[next_entry]<=1;reasons[next_entry]<=fail_reason;busy[next_bank]<=0;
                end
                frames_dropped<=add_sat(frames_dropped,{1'b0,(push && capturing)}+{1'b0,((push && !allocate) || fail)});
                if(state==CMD && command_valid && command_ready) begin
                    if(kinds[rd_ptr]) state<=FENCE;
                    else begin state<=DATA;read_index<=0;pending<=0;held_valid<=0;end
                end
                if(read_issue) pending<=1;
                if(pending) begin pending<=0;held_valid<=1;held_data<=bank_id[rd_ptr] ? read1 : read0;end
                if(pixel_valid && pixel_ready) begin
                    held_valid<=0;
                    if(pixel_last) state<=FENCE;else read_index<=read_index+1'b1;
                end
            end
        end
    end
    // synthesis translate_off
    initial if(FRAME_PIXELS<1 || DEPTH<1) $fatal(1,"FAIL: capture source parameters");
    // synthesis translate_on
endmodule
