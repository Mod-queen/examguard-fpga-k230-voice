`timescale 1ns/1ps
// Single-master open-drain byte engine. No generated clocks: all logic on clk.
// Command: 0 START/repeated START, 1 WRITE+slave ACK, 2 READ+master ACK/NACK,
// 3 STOP. Caller retains exclusive bus ownership from START through STOP.
// Response held until ready. WRITE NACK is ack=0 (not a transport error).
// error: 0 success, 2 line timeout, 3 invalid command/bus state. A timeout
// releases both lines, invalidates bus_active; caller must start a new transfer.
module i2c_byte_master #(
    parameter integer QUARTER_CYCLES=125, // 50MHz / (4*125) ~= 100kHz
    parameter integer TIMEOUT_CYCLES=500000,
    parameter integer CW=$clog2(2*QUARTER_CYCLES),
    parameter integer TW=TIMEOUT_CYCLES<2?1:$clog2(TIMEOUT_CYCLES)
)(
    input wire clk,rst,
    input wire cmd_valid,output wire cmd_ready,input wire [1:0] cmd_op,
    input wire [7:0] cmd_data,input wire cmd_read_nack,
    output reg rsp_valid,input wire rsp_ready,
    output reg [7:0] rsp_data,output reg rsp_ack,output reg [1:0] rsp_error,
    input wire scl_i,sda_i,
    output reg scl_low,sda_low,
    output reg bus_active
);
    localparam IDLE=0,START_LOW=1,START_WAIT=2,START_HIGH=3,START_HOLD=4,
        BIT_LOW=5,BIT_WAIT=6,BIT_HIGH=7,BIT_END=8,
        STOP_LOW=9,STOP_WAIT=10,STOP_HIGH=11,STOP_RELEASE=12;
    reg [3:0] state;
    reg [CW-1:0] delay_count;
    reg [TW-1:0] wait_count;
    reg [3:0] bit_index;
    reg [7:0] shift;
    reg reading,read_nack;
    (* ASYNC_REG="TRUE" *) reg scl_meta,scl_sync,sda_meta,sda_sync;
    always @(posedge clk) begin
        if(rst) begin scl_meta<=1;scl_sync<=1;sda_meta<=1;sda_sync<=1;end
        else begin scl_meta<=scl_i;scl_sync<=scl_meta;sda_meta<=sda_i;sda_sync<=sda_meta;end
    end
    assign cmd_ready=!rst && state==IDLE && !rsp_valid;
    task finish;
        input [1:0] error_code;
        begin state<=IDLE;rsp_valid<=1;rsp_error<=error_code;delay_count<=0;wait_count<=0;end
    endtask
    task timeout_release;
        begin scl_low<=0;sda_low<=0;bus_active<=0;finish(2);end
    endtask
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;scl_low<=0;sda_low<=0;bus_active<=0;
            rsp_valid<=0;rsp_data<=0;rsp_ack<=0;rsp_error<=0;
            delay_count<=0;wait_count<=0;bit_index<=0;shift<=0;reading<=0;read_nack<=0;
        end else begin
            if(rsp_valid && rsp_ready) rsp_valid<=0;
            case(state)
                IDLE:if(cmd_valid && cmd_ready) begin
                    rsp_ack<=0;rsp_data<=0;rsp_error<=0;delay_count<=0;wait_count<=0;
                    case(cmd_op)
                        0:begin
                            scl_low<=bus_active;sda_low<=0;
                            state<=bus_active ? START_LOW : START_WAIT;
                        end
                        1,2:if(!bus_active) finish(3);
                        else begin
                            reading<=cmd_op==2;read_nack<=cmd_read_nack;shift<=cmd_data;
                            bit_index<=0;scl_low<=1;
                            sda_low<=cmd_op==1 && !cmd_data[7];state<=BIT_LOW;
                        end
                        3:if(!bus_active) finish(3);
                        else begin scl_low<=1;sda_low<=1;state<=STOP_LOW;end
                    endcase
                end
                START_LOW:if(delay_count==QUARTER_CYCLES-1) begin
                    delay_count<=0;scl_low<=0;state<=START_WAIT;
                end else delay_count<=delay_count+1'b1;
                START_WAIT:if(scl_sync && sda_sync) begin delay_count<=0;wait_count<=0;state<=START_HIGH;end
                else if(wait_count==TIMEOUT_CYCLES-1) timeout_release();
                else wait_count<=wait_count+1'b1;
                START_HIGH:if(delay_count==2*QUARTER_CYCLES-1) begin
                    delay_count<=0;sda_low<=1;bus_active<=1;state<=START_HOLD;
                end else delay_count<=delay_count+1'b1;
                START_HOLD:if(delay_count==2*QUARTER_CYCLES-1) begin scl_low<=1;finish(0);end
                else delay_count<=delay_count+1'b1;
                BIT_LOW:if(delay_count==QUARTER_CYCLES-1) begin
                    delay_count<=0;wait_count<=0;scl_low<=0;state<=BIT_WAIT;
                end else delay_count<=delay_count+1'b1;
                BIT_WAIT:if(scl_sync) begin delay_count<=0;wait_count<=0;state<=BIT_HIGH;end
                else if(wait_count==TIMEOUT_CYCLES-1) timeout_release();
                else wait_count<=wait_count+1'b1;
                BIT_HIGH:if(delay_count==2*QUARTER_CYCLES-1) begin
                    delay_count<=0;scl_low<=1;state<=BIT_END;
                    if(bit_index<8 && reading) shift<={shift[6:0],sda_sync};
                    if(bit_index==8 && !reading) rsp_ack<=!sda_sync;
                end else delay_count<=delay_count+1'b1;
                BIT_END:if(delay_count==QUARTER_CYCLES-1) begin
                    delay_count<=0;
                    if(bit_index==8) begin sda_low<=0;rsp_data<=shift;finish(0);end
                    else begin
                        bit_index<=bit_index+1'b1;state<=BIT_LOW;
                        if(bit_index==7) sda_low<=reading && !read_nack;
                        else sda_low<=!reading && !shift[6-bit_index];
                    end
                end else delay_count<=delay_count+1'b1;
                STOP_LOW:if(delay_count==QUARTER_CYCLES-1) begin
                    delay_count<=0;wait_count<=0;scl_low<=0;state<=STOP_WAIT;
                end else delay_count<=delay_count+1'b1;
                STOP_WAIT:if(scl_sync) begin delay_count<=0;wait_count<=0;state<=STOP_HIGH;end
                else if(wait_count==TIMEOUT_CYCLES-1) timeout_release();
                else wait_count<=wait_count+1'b1;
                STOP_HIGH:if(delay_count==2*QUARTER_CYCLES-1) begin delay_count<=0;sda_low<=0;state<=STOP_RELEASE;end
                else delay_count<=delay_count+1'b1;
                STOP_RELEASE:if(sda_sync) begin
                    if(delay_count==2*QUARTER_CYCLES-1) begin bus_active<=0;finish(0);end
                    else delay_count<=delay_count+1'b1;
                end else if(wait_count==TIMEOUT_CYCLES-1) timeout_release();
                else wait_count<=wait_count+1'b1;
                default:begin scl_low<=0;sda_low<=0;bus_active<=0;finish(3);end
            endcase
        end
    end
    // synthesis translate_off
    initial if(QUARTER_CYCLES<2 || TIMEOUT_CYCLES<4) $fatal(1,"FAIL: I2C timing parameters");
    // synthesis translate_on
endmodule
