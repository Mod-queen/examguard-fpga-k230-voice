`timescale 1ns/1ps
// One owner for shared RTC/EEPROM I2C. Atomic request from START to STOP.
// addr_bytes=0: probe/address only; 1: PCF8563 register; 2: 24LC64 word address.
// wr_count OR rd_count 0..32. For reads, writes register pointer then repeated
// START/addressR. Byte0 is at payload[7:0]. Response valid/data/error held.
// Caller handles EEPROM page limits, ACK polling deadline and readback verify.
// error: 0 success, 1 slave NACK, 2 line timeout, 3 invalid request.
module i2c_register_master #(
    parameter integer QUARTER_CYCLES=125,TIMEOUT_CYCLES=500000
)(
    input wire clk,rst,
    input wire req_valid,output wire req_ready,
    input wire [6:0] req_device,input wire [1:0] req_addr_bytes,
    input wire [15:0] req_address,
    input wire [5:0] req_wr_count,req_rd_count,input wire [255:0] req_wr_data,
    output reg rsp_valid,input wire rsp_ready,
    output reg [1:0] rsp_error,output reg [255:0] rsp_rd_data,
    input wire scl_i,sda_i,output wire scl_low,sda_low
);
    localparam IDLE=0,GO=1,WAIT=2;
    localparam START=0,ADDRW=1,REGHI=2,REGLO=3,WRITE=4,RESTART=5,ADDRR=6,READ=7,STOP=8;
    reg [1:0] state;
    reg [3:0] stage;
    reg [6:0] device;
    reg [1:0] addr_bytes;
    reg [15:0] address;
    reg [5:0] wr_count,rd_count,index;
    reg [255:0] wr_data;
    wire cmd_ready,byte_valid,byte_ack,bus_active;
    wire [7:0] byte_data;
    wire [1:0] byte_error;
    reg [1:0] cmd_op;
    reg [7:0] cmd_data;
    always @* begin
        cmd_op=1;cmd_data=0;
        case(stage)
            START,RESTART:cmd_op=0;
            ADDRW:cmd_data={device,1'b0};
            ADDRR:cmd_data={device,1'b1};
            REGHI:cmd_data=address[15:8];
            REGLO:cmd_data=address[7:0];
            WRITE:cmd_data=wr_data[index*8 +: 8];
            READ:cmd_op=2;
            STOP:cmd_op=3;
        endcase
    end
    i2c_byte_master #(.QUARTER_CYCLES(QUARTER_CYCLES),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) bytes(
        .clk(clk),.rst(rst),.cmd_valid(state==GO),.cmd_ready(cmd_ready),.cmd_op(cmd_op),.cmd_data(cmd_data),
        .cmd_read_nack(index==rd_count-1),.rsp_valid(byte_valid),.rsp_ready(state==WAIT),
        .rsp_data(byte_data),.rsp_ack(byte_ack),.rsp_error(byte_error),
        .scl_i(scl_i),.sda_i(sda_i),.scl_low(scl_low),.sda_low(sda_low),.bus_active(bus_active));
    assign req_ready=!rst && state==IDLE && !rsp_valid;
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;stage<=START;device<=0;addr_bytes<=0;address<=0;
            wr_count<=0;rd_count<=0;index<=0;wr_data<=0;rsp_valid<=0;rsp_error<=0;rsp_rd_data<=0;
        end else begin
            if(rsp_valid && rsp_ready) rsp_valid<=0;
            case(state)
                IDLE:if(req_valid && req_ready) begin
                    rsp_error<=0;rsp_rd_data<=0;
                    if(req_addr_bytes>2 || req_wr_count>32 || req_rd_count>32 ||
                        (req_wr_count!=0 && req_rd_count!=0) || (req_addr_bytes==0 && (req_wr_count!=0 || req_rd_count!=0))) begin
                        rsp_valid<=1;rsp_error<=3;
                    end else begin
                        device<=req_device;addr_bytes<=req_addr_bytes;address<=req_address;
                        wr_count<=req_wr_count;rd_count<=req_rd_count;wr_data<=req_wr_data;
                        index<=0;stage<=START;state<=GO;
                    end
                end
                GO:if(cmd_ready) state<=WAIT;
                WAIT:if(byte_valid) begin
                    if(byte_error!=0) begin
                        rsp_error<=byte_error;state<=IDLE;rsp_valid<=1;
                    end else if(stage==STOP) begin state<=IDLE;rsp_valid<=1;end
                    else if(cmd_op==1 && !byte_ack) begin rsp_error<=1;stage<=STOP;state<=GO;end
                    else begin
                        state<=GO;
                        case(stage)
                            START:stage<=ADDRW;
                            ADDRW:stage<=addr_bytes==2 ? REGHI : addr_bytes==1 ? REGLO : STOP;
                            REGHI:stage<=REGLO;
                            REGLO:stage<=rd_count!=0 ? RESTART : wr_count!=0 ? WRITE : STOP;
                            WRITE:if(index==wr_count-1) stage<=STOP;else index<=index+1'b1;
                            RESTART:stage<=ADDRR;
                            ADDRR:begin stage<=READ;index<=0;end
                            READ:begin
                                rsp_rd_data[index*8 +: 8]<=byte_data;
                                if(index==rd_count-1) stage<=STOP;else index<=index+1'b1;
                            end
                            default:begin rsp_error<=3;stage<=STOP;end
                        endcase
                    end
                end
            endcase
        end
    end
endmodule
