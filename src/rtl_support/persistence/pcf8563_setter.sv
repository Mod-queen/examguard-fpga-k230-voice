`timescale 1ns/1ps
// Explicit maintenance-only RTC setting client for the shared register bus.
// calendar byte0=seconds, then minute/hour/day/weekday/month/year, canonical BCD.
// No EEPROM or event-clock access. Caller owns the maintenance lock through result.
// Common reset must cancel master too; a reset/power cut during setting can leave
// STOP set. Error is not retried: a single best-effort RUN follows uncertain writes.
// error: 0 verified, 1 not authorized/maintenance, 2 invalid date, 3 bus error,
// 4 unsupported control0, 5 stopped readback mismatch, 6 running readback mismatch.
module pcf8563_setter #(
    parameter [31:0] MAX_READ_CYCLES=25000000
)(
    input wire clk,rst,
    input wire set_valid,output wire set_ready,
    input wire maintenance,authorize,input wire [55:0] calendar_data,
    output reg result_valid,input wire result_ready,
    output reg [3:0] result_error,output reg [1:0] recovery_error,
    output reg write_attempted,output reg [71:0] snapshot,
    output wire bus_req_valid,input wire bus_req_ready,
    output wire [6:0] bus_device,output wire [1:0] bus_addr_bytes,
    output wire [15:0] bus_address,output wire [5:0] bus_wr_count,bus_rd_count,
    output wire [255:0] bus_wr_data,
    input wire bus_rsp_valid,output wire bus_rsp_ready,
    input wire [1:0] bus_error,input wire [255:0] bus_rd_data
);
    localparam IDLE=0,ISSUE=1,WAIT=2,VERIFY_START=3,VERIFY_WAIT=4;
    localparam CONTROL=0,STOP_CLOCK=1,WRITE_DATE=2,CHECK_DATE=3,RUN_CLOCK=4,RECOVER=5;
    reg [2:0] state,phase;
    reg [55:0] target;
    wire input_valid;
    pcf8563_calendar validate(.raw({calendar_data,16'd0}),.valid(input_valid),
        .voltage_low(),.stopped(),.unsupported_century(),.year(),.month(),.day(),
        .hour(),.minute(),.second(),.weekday());
    wire canonical=(calendar_data[7:0]&8'h80)==0 && (calendar_data[15:8]&8'h80)==0 &&
        (calendar_data[23:16]&8'hc0)==0 && (calendar_data[31:24]&8'hc0)==0 &&
        (calendar_data[39:32]&8'hf8)==0 && (calendar_data[47:40]&8'he0)==0;

    function automatic [7:0] inc_bcd(input [7:0] v);
        inc_bcd=v[3:0]==9 ? {v[7:4]+4'd1,4'd0} : v+8'd1;
    endfunction
    function automatic [55:0] next_second(input [55:0] date);
        reg [7:0] s,m,h,d,w,mo,y,days;
        reg leap;
        begin
            s=date[7:0];m=date[15:8];h=date[23:16];
            d=date[31:24];w=date[39:32];mo=date[47:40];y=date[55:48];
            // decimal year mod4: tens*10+ones -> tens*2+ones mod4.
            leap=({y[4],1'b0}+y[1:0])==2'd0;
            days=mo==8'h02 ? (leap?8'h29:8'h28) :
                ((mo==8'h04||mo==8'h06||mo==8'h09||mo==8'h11)?8'h30:8'h31);
            if(s!=8'h59) s=inc_bcd(s);
            else begin
                s=0;
                if(m!=8'h59) m=inc_bcd(m);
                else begin
                    m=0;
                    if(h!=8'h23) h=inc_bcd(h);
                    else begin
                        h=0;w=w==6?0:w+8'd1;
                        if(d!=days) d=inc_bcd(d);
                        else begin
                            d=1;
                            if(mo!=8'h12) mo=inc_bcd(mo);
                            else begin mo=1;y=inc_bcd(y);end
                        end
                    end
                end
            end
            // 2099->2100 is outside the frozen RTC calendar range.
            if(y==8'ha0) next_second=56'hffffffffffffff;
            else next_second={y,mo,w,d,h,m,s};
        end
    endfunction

    wire reader_ready,reader_valid,reader_req,reader_rsp_ready;
    wire [1:0] reader_error;
    wire [71:0] reader_snapshot;
    wire [15:0] reader_address;
    wire [5:0] reader_rd_count;
    wire verify_active=state==VERIFY_START || state==VERIFY_WAIT;
    pcf8563_reader #(.MAX_READ_CYCLES(MAX_READ_CYCLES)) reader(
        .clk(clk),.rst(rst),.refresh_valid(state==VERIFY_START),.refresh_ready(reader_ready),
        .result_valid(reader_valid),.result_ready(state==VERIFY_WAIT),.result_error(reader_error),
        .snapshot(reader_snapshot),.known(),.fresh(),.age_cycles(),.year(),.month(),.day(),
        .hour(),.minute(),.second(),.weekday(),.bus_req_valid(reader_req),
        .bus_req_ready(verify_active && bus_req_ready),.bus_device(),.bus_addr_bytes(),
        .bus_address(reader_address),.bus_wr_count(),.bus_rd_count(reader_rd_count),.bus_wr_data(),
        .bus_rsp_valid(verify_active && bus_rsp_valid),.bus_rsp_ready(reader_rsp_ready),
        .bus_error(bus_error),.bus_rd_data(bus_rd_data));
    assign set_ready=!rst && state==IDLE && !result_valid;
    assign bus_req_valid=!rst && (verify_active ? reader_req : state==ISSUE);
    assign bus_rsp_ready=!rst && (verify_active ? reader_rsp_ready : state==WAIT);
    assign bus_device=7'h51;
    assign bus_addr_bytes=1;
    assign bus_address=verify_active ? reader_address : phase==WRITE_DATE ? 16'd2 : 16'd0;
    assign bus_wr_count=verify_active || phase==CONTROL || phase==CHECK_DATE ? 0 : phase==WRITE_DATE ? 7 : 1;
    assign bus_rd_count=verify_active ? reader_rd_count : phase==CONTROL ? 1 : phase==CHECK_DATE ? 9 : 0;
    assign bus_wr_data=phase==WRITE_DATE ? {200'd0,target} : phase==STOP_CLOCK ? 256'h20 : 256'd0;
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;phase<=CONTROL;target<=0;result_valid<=0;result_error<=0;
            recovery_error<=0;write_attempted<=0;snapshot<=0;
        end else begin
            if(result_valid && result_ready) result_valid<=0;
            case(state)
                IDLE:if(set_valid && set_ready) begin
                    result_error<=0;recovery_error<=0;write_attempted<=0;snapshot<=0;
                    if(!maintenance || !authorize) begin result_error<=1;result_valid<=1;end
                    else if(!input_valid || !canonical) begin result_error<=2;result_valid<=1;end
                    else begin target<=calendar_data;phase<=CONTROL;state<=ISSUE;end
                end
                ISSUE:if(bus_req_ready) begin
                    if(bus_wr_count!=0) write_attempted<=1;
                    state<=WAIT;
                end
                WAIT:if(bus_rsp_valid) begin
                    if(phase==RECOVER) begin
                        recovery_error<=bus_error;result_valid<=1;state<=IDLE;
                    end else if(bus_error!=0) begin
                        result_error<=3;
                        if(write_attempted) begin phase<=RECOVER;state<=ISSUE;end
                        else begin result_valid<=1;state<=IDLE;end
                    end else case(phase)
                        CONTROL:if((bus_rd_data[7:0]&8'hdf)!=0) begin
                            result_error<=4;result_valid<=1;state<=IDLE;
                        end else begin phase<=STOP_CLOCK;state<=ISSUE;end
                        STOP_CLOCK:begin phase<=WRITE_DATE;state<=ISSUE;end
                        WRITE_DATE:begin phase<=CHECK_DATE;state<=ISSUE;end
                        CHECK_DATE:begin
                            snapshot<=bus_rd_data[71:0];
                            if(bus_rd_data[71:16]!=target || bus_rd_data[7:0]!=8'h20) begin
                                result_error<=5;phase<=RECOVER;state<=ISSUE;
                            end else begin phase<=RUN_CLOCK;state<=ISSUE;end
                        end
                        RUN_CLOCK:state<=VERIFY_START;
                        default:begin result_error<=6;result_valid<=1;state<=IDLE;end
                    endcase
                end
                VERIFY_START:if(reader_ready) state<=VERIFY_WAIT;
                VERIFY_WAIT:if(reader_valid) begin
                    snapshot<=reader_snapshot;
                    if(reader_error!=0 || (reader_snapshot[71:16]!=target && reader_snapshot[71:16]!=next_second(target)))
                        result_error<=6;
                    result_valid<=1;state<=IDLE;
                end
            endcase
        end
    end
endmodule
