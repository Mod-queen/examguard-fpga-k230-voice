`timescale 1ns/1ps
// One physical WonderEcho bus. Source 0=information, 1=preparation/help,
// 2=stage/alarm (caller buffers its pulse). Packed source0 at low slice.
// Arbitration is round-robin, with a due poll between consecutive writes.
// Completion is WRITE ACK/STOP, never evidence of audio playback completion.
module voice_interaction_bus #(
    parameter integer QUARTER_CYCLES=125,
    parameter integer TIMEOUT_CYCLES=500000,
    parameter integer POLL_CYCLES=2500000,
    parameter integer STALE_CYCLES=25000000
) (
    input wire clk,rst,
    input wire [31:0] round_id,
    input wire [63:0] info_tag,
    input wire poll_eligible,
    input wire [2:0] req_valid,
    output reg [2:0] req_ready,
    input wire [23:0] req_type,req_id,
    input wire [95:0] req_cookie,req_round,
    input wire [191:0] req_tag,
    output reg done_valid,
    input wire done_ready,
    output reg [1:0] done_owner,
    output reg [31:0] done_cookie,done_round,
    output reg [63:0] done_tag,
    output reg [1:0] done_error,
    output reg sample_valid,
    output reg sample_eligible,
    output reg [7:0] sample_id,
    output reg [31:0] sample_round,
    output reg [63:0] sample_tag,
    output wire link_fresh,
    output wire busy,
    input wire scl_i,sda_i,
    output wire scl_low,sda_low
);
    localparam [1:0] IDLE=0,ISSUE=1,WAIT_RESPONSE=2;
    reg [1:0] phase, next_owner;
    reg write_op,prefer_poll;
    reg [7:0] held_type,held_id;
    reg [31:0] poll_count,age;
    reg poll_known;
    reg [31:0] poll_round;
    reg [63:0] poll_tag;
    reg found;
    reg [1:0] selected;
    integer offset,index;
    wire bus_ready,bus_valid;
    wire [1:0] bus_error;
    wire [255:0] bus_data;
    wire poll_due = poll_count >= POLL_CYCLES-1;
    assign busy = phase!=IDLE || done_valid;
    assign link_fresh = !rst && poll_known && age<STALE_CYCLES &&
                        poll_round==round_id && poll_tag==info_tag;
    always @* begin
        found=0;selected=0;req_ready=0;
        for(offset=0;offset<3;offset=offset+1) begin
            index=next_owner+offset;
            if(index>=3) index=index-3;
            if(!found && req_valid[index]) begin found=1;selected=index;end
        end
        if(!rst && phase==IDLE && !done_valid && !(poll_due && prefer_poll) && found)
            req_ready[selected]=1;
    end
    i2c_register_master #(.QUARTER_CYCLES(QUARTER_CYCLES),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) bus(
        .clk(clk),.rst(rst),.req_valid(phase==ISSUE),.req_ready(bus_ready),
        .req_device(7'h34),.req_addr_bytes(2'd1),
        .req_address(write_op ? 16'h006e : 16'h0064),
        .req_wr_count(write_op ? 6'd2 : 6'd0),.req_rd_count(write_op ? 6'd0 : 6'd1),
        .req_wr_data({240'd0,held_id,held_type}),
        .rsp_valid(bus_valid),.rsp_ready(phase==WAIT_RESPONSE),
        .rsp_error(bus_error),.rsp_rd_data(bus_data),
        .scl_i(scl_i),.sda_i(sda_i),.scl_low(scl_low),.sda_low(sda_low));
    always @(posedge clk) begin
        if(rst) begin
            phase<=IDLE;next_owner<=0;write_op<=0;prefer_poll<=1;
            held_type<=0;held_id<=0;poll_count<=0;age<=STALE_CYCLES;
            poll_known<=0;poll_round<=0;poll_tag<=0;
            done_valid<=0;done_owner<=0;done_cookie<=0;done_round<=0;done_tag<=0;done_error<=0;
            sample_valid<=0;sample_id<=0;sample_round<=0;sample_tag<=0;
            sample_eligible<=0;
        end else begin
            sample_valid<=0;
            if(age<STALE_CYCLES) age<=age+1'b1;
            if(!poll_due) poll_count<=poll_count+1'b1;
            if(done_valid && done_ready) done_valid<=0;
            case(phase)
                IDLE:if(!done_valid) begin
                    if(|req_ready) begin
                        write_op<=1;held_type<=req_type[selected*8 +:8];held_id<=req_id[selected*8 +:8];
                        done_owner<=selected;done_cookie<=req_cookie[selected*32 +:32];
                        done_round<=req_round[selected*32 +:32];done_tag<=req_tag[selected*64 +:64];
                        next_owner<=selected==2 ? 0 : selected+1'b1;
                        phase<=ISSUE;prefer_poll<=1;
                    end else if(poll_due) begin
                        write_op<=0;sample_round<=round_id;sample_tag<=info_tag;
                        sample_eligible<=poll_eligible;
                        phase<=ISSUE;prefer_poll<=0;poll_count<=0;
                    end
                end
                ISSUE:if(bus_ready) phase<=WAIT_RESPONSE;
                WAIT_RESPONSE:if(bus_valid) begin
                    phase<=IDLE;
                    if(write_op) begin
                        done_valid<=1;done_error<=bus_error;
                        if(bus_error!=0) begin poll_known<=0;age<=STALE_CYCLES;end
                    end else if(bus_error==0) begin
                        sample_valid<=1;sample_id<=bus_data[7:0];
                        poll_known<=1;age<=0;poll_round<=sample_round;poll_tag<=sample_tag;
                    end else begin poll_known<=0;age<=STALE_CYCLES;end
                end
                default:phase<=IDLE;
            endcase
        end
    end
endmodule
