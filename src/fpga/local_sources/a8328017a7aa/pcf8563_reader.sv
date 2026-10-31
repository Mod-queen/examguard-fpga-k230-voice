`timescale 1ns/1ps
// Read-only RTC client on the common register bus. Request a refresh; response
// held until consumed. Existing date becomes invalid on a failed refresh.
// Full registers0..8 burst then seconds reread guards a rollover. Retry at most
// twice, no endless busy loop. Never writes/initializes RTC or monotonic time.
// error: 0 trusted, 1 I2C, 2 invalid calendar/VL/STOP/century, 3 unstable seconds.
module pcf8563_reader #(
    parameter [31:0] STALE_CYCLES=100000000,
    parameter [31:0] MAX_READ_CYCLES=25000000 // 0.5s at50MHz, strictly <60s
)(
    input wire clk,rst,
    input wire refresh_valid,output wire refresh_ready,
    output reg result_valid,input wire result_ready,output reg [1:0] result_error,
    output reg [71:0] snapshot,output reg known,output wire fresh,
    output reg [31:0] age_cycles,
    output wire [15:0] year,output wire [7:0] month,day,hour,minute,second,
    output wire [2:0] weekday,
    output wire bus_req_valid,input wire bus_req_ready,
    output wire [6:0] bus_device,output wire [1:0] bus_addr_bytes,
    output wire [15:0] bus_address,output wire [5:0] bus_wr_count,bus_rd_count,
    output wire [255:0] bus_wr_data,
    input wire bus_rsp_valid,output wire bus_rsp_ready,
    input wire [1:0] bus_error,input wire [255:0] bus_rd_data
);
    localparam IDLE=0,ISSUE=1,WAIT=2;
    reg [1:0] state,retries;
    reg verify_second;
    reg [71:0] candidate;
    reg [31:0] read_age;
    wire calendar_valid;
    pcf8563_calendar calendar(.raw(candidate),.valid(calendar_valid),.voltage_low(),.stopped(),.unsupported_century(),
        .year(),.month(),.day(),.hour(),.minute(),.second(),.weekday());
    pcf8563_calendar displayed(.raw(snapshot),.valid(),.voltage_low(),.stopped(),.unsupported_century(),
        .year(year),.month(month),.day(day),.hour(hour),.minute(minute),.second(second),.weekday(weekday));
    assign refresh_ready=!rst && state==IDLE && !result_valid;
    assign fresh=known && age_cycles<=STALE_CYCLES;
    assign bus_req_valid=!rst && state==ISSUE;
    assign bus_rsp_ready=!rst && state==WAIT;
    assign bus_device=7'h51;assign bus_addr_bytes=1;assign bus_address=verify_second?16'd2:16'd0;
    assign bus_wr_count=0;assign bus_wr_data=0;assign bus_rd_count=verify_second?1:9;
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;retries<=0;verify_second<=0;candidate<=0;snapshot<=0;
            known<=0;age_cycles<=32'hffffffff;result_valid<=0;result_error<=0;read_age<=0;
        end else begin
            if(state!=IDLE && read_age!=32'hffffffff) read_age<=read_age+1'b1;
            if(known && age_cycles!=32'hffffffff) age_cycles<=age_cycles+1'b1;
            if(result_valid && result_ready) result_valid<=0;
            case(state)
                IDLE:if(refresh_valid && refresh_ready) begin state<=ISSUE;retries<=0;verify_second<=0;read_age<=0;end
                ISSUE:if(bus_req_ready) state<=WAIT;
                WAIT:if(bus_rsp_valid) begin
                    if(read_age>=MAX_READ_CYCLES) begin known<=0;result_error<=3;result_valid<=1;state<=IDLE;end
                    else if(bus_error!=0) begin known<=0;result_error<=1;result_valid<=1;state<=IDLE;end
                    else if(!verify_second) begin candidate<=bus_rd_data[71:0];verify_second<=1;state<=ISSUE;end
                    else if(!calendar_valid || bus_rd_data[7]) begin known<=0;result_error<=2;result_valid<=1;state<=IDLE;end
                    else if(bus_rd_data[6:0]!=candidate[22:16]) begin
                        if(retries==2) begin known<=0;result_error<=3;result_valid<=1;state<=IDLE;end
                        else begin retries<=retries+1'b1;verify_second<=0;state<=ISSUE;end
                    end else begin
                        snapshot<=candidate;known<=1;age_cycles<=0;result_error<=0;result_valid<=1;state<=IDLE;
                    end
                end
            endcase
        end
    end
endmodule
