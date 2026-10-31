`timescale 1ns/1ps
// 24LC64 verified single-page write service on shared register transaction bus.
// Reject zero/>32/cross-page/out-of-8KiB writes BEFORE touching the bus.
// ACK polling bounded by MAX_POLLS (transaction engine bounds each bus op).
// ACK alone isn't commit: full readback equality required (detects WP too).
// Caller owns dual-slot ordering/CRC/generation; success does not imply
// whole-record atomicity and a timeout must not automatically reuse a boot ID.
// result_error: 0 verified, 1 I2C failure, 2 invalid shape, 3 poll exhausted,
// 4 readback mismatch. No implicit retry of the write itself.
module eeprom_page_writer #(parameter integer MAX_POLLS=128)(
    input wire clk,rst,
    input wire write_valid,output wire write_ready,
    input wire [12:0] write_address,input wire [5:0] write_count,input wire [255:0] write_data,
    output reg result_valid,input wire result_ready,output reg [2:0] result_error,
    output wire bus_req_valid,input wire bus_req_ready,
    output wire [6:0] bus_device,output wire [1:0] bus_addr_bytes,
    output wire [15:0] bus_address,output wire [5:0] bus_wr_count,bus_rd_count,
    output wire [255:0] bus_wr_data,
    input wire bus_rsp_valid,output wire bus_rsp_ready,
    input wire [1:0] bus_error,input wire [255:0] bus_rd_data
);
    localparam IDLE=0,ISSUE=1,WAIT=2;
    localparam WRITE=0,POLL=1,VERIFY=2;
    reg [1:0] state,stage;
    reg [12:0] address;
    reg [5:0] count;
    reg [255:0] data;
    reg [$clog2(MAX_POLLS+1)-1:0] polls;
    reg mismatch;
    integer i;
    always @* begin
        mismatch=0;
        for(i=0;i<32;i=i+1) if(i<count && bus_rd_data[i*8 +: 8]!=data[i*8 +: 8]) mismatch=1;
    end
    assign write_ready=!rst && state==IDLE && !result_valid;
    assign bus_req_valid=!rst && state==ISSUE;
    assign bus_rsp_ready=!rst && state==WAIT;
    assign bus_device=7'h50;assign bus_addr_bytes=stage==POLL?0:2;
    assign bus_address={3'd0,address};assign bus_wr_data=data;
    assign bus_wr_count=stage==WRITE?count:0;
    assign bus_rd_count=stage==VERIFY?count:0;
    task finish(input [2:0] error_code);
        begin state<=IDLE;result_valid<=1;result_error<=error_code;end
    endtask
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;stage<=WRITE;address<=0;count<=0;data<=0;polls<=0;result_valid<=0;result_error<=0;
        end else begin
            if(result_valid && result_ready) result_valid<=0;
            case(state)
                IDLE:if(write_valid && write_ready) begin
                    if(write_count==0 || write_count>32 || {1'b0,write_address[4:0]}+write_count>32 ||
                        {1'b0,write_address}+write_count>8192) finish(2);
                    else begin
                        address<=write_address;count<=write_count;data<=write_data;polls<=0;
                        state<=ISSUE;stage<=WRITE;
                    end
                end
                ISSUE:if(bus_req_ready) state<=WAIT;
                WAIT:if(bus_rsp_valid) begin
                    if(stage==POLL && bus_error==1) begin
                        if(polls==MAX_POLLS-1) finish(3);
                        else begin polls<=polls+1'b1;state<=ISSUE;end
                    end else if(bus_error!=0) finish(1);
                    else if(stage==WRITE) begin stage<=POLL;state<=ISSUE;end
                    else if(stage==POLL) begin stage<=VERIFY;state<=ISSUE;end
                    else if(mismatch) finish(4);
                    else finish(0);
                end
            endcase
        end
    end
    // synthesis translate_off
    initial if(MAX_POLLS<1) $fatal(1,"FAIL: EEPROM polling bound");
    // synthesis translate_on
endmodule
