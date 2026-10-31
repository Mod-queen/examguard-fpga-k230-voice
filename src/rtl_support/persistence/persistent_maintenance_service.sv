`timescale 1ns/1ps
// Boot first; then periodic anchors OR a held maintenance operation. ONE store
// and ONE physical master. Maintenance waits for the entire prior RA packet to
// drain, so no pre-write anchor is mistaken for the post-write clock state.
// opcode: 0 LOAD_CONFIG, 1 SAVE_CONFIG, 2 SET_RTC. No FORMAT/NEXT_BOOT host API.
// error: 0 success, 1 unavailable/active exam, 2 opcode, 3 config, 4 RTC.
module persistent_maintenance_service #(
    parameter integer STARTUP_CYCLES=2500000,QUARTER_CYCLES=125,
    parameter integer TIMEOUT_CYCLES=500000,MAX_POLLS=128,REFRESH_CYCLES=50000000,
    parameter [31:0] RTC_STALE_CYCLES=100000000,RTC_MAX_READ_CYCLES=25000000
)(
    input wire clk,rst,input wire [31:0] expected_device,input wire [63:0] monotonic_ms,
    input wire scl_i,sda_i,output wire scl_low,sda_low,
    output wire admission,done,output wire [3:0] error,
    output wire [31:0] boot_id,generation,output wire active_slot,
    output wire rtc_known,rtc_fresh,output wire [31:0] rtc_age_cycles,
    output wire byte_valid,byte_last,output wire [7:0] byte_data,input wire byte_ready,
    input wire request_valid,output wire request_ready,input wire [1:0] opcode,
    input wire maintenance_allowed,input wire [255:0] proposed_config,input wire [55:0] calendar_data,
    output wire maintenance_busy,output reg result_valid,input wire result_ready,
    output reg [1:0] result_opcode,output reg [3:0] result_error,result_detail,result_store_error,
    output reg [1:0] result_recovery_error,output reg result_write_attempted,
    output reg [71:0] result_snapshot,
    output reg config_known,output reg [255:0] active_config,output reg [31:0] config_generation
);
    localparam IDLE=0,DRAIN=1,CFG_START=2,CFG_WAIT=3,RTC_START=4,RTC_WAIT=5,HOLD=6;
    reg [2:0] state;
    reg [255:0] held_config;reg [55:0] held_calendar;reg config_write_attempted;
    reg [31:0] startup;reg started,boot_published;
    wire start=!started && startup==STARTUP_CYCLES-1;
    always @(posedge clk) begin
        if(rst) begin startup<=0;started<=0;end
        else if(!started) begin if(start) started<=1;else startup<=startup+1'b1;end
    end
    wire gate_valid,gate_ready,gate_rsp_ready;
    wire [1:0] gate_cmd;wire [31:0] gate_device;wire [255:0] gate_config;
    wire ds_ready,ds_valid,ds_loaded;wire [3:0] ds_error;
    wire [31:0] ds_device,ds_boot;wire [255:0] ds_config;
    persistent_boot_gate gate(.clk(clk),.rst(rst),.start(start),.format_blank(1'b0),
        .device(expected_device),.initial_config(256'd0),.store_cmd_valid(gate_valid),.store_cmd_ready(gate_ready),
        .store_cmd(gate_cmd),.store_device(gate_device),.store_config(gate_config),
        .store_result_valid(ds_valid && !done),.store_result_ready(gate_rsp_ready),
        .store_error(ds_error),.store_loaded(ds_loaded),.store_boot(ds_boot),
        .admission(admission),.done(done),.error(error),.boot_id(boot_id));
    assign gate_ready=ds_ready && !done;
    wire cfg_valid,cfg_ready,cfg_result,cfg_known;wire [3:0] cfg_error,cfg_store_error;
    wire [1:0] cfg_cmd;wire [31:0] cfg_device,cfg_generation;wire [255:0] cfg_data,cfg_active;
    wire cfg_rsp_ready,cfg_write;
    assign cfg_write=state==CFG_START || state==CFG_WAIT;
    persistent_config_manager config_manager(.clk(clk),.rst(rst),
        .request_valid(state==CFG_START),.request_ready(cfg_ready),.save(result_opcode==1),
        .maintenance(1'b1),.authorize(1'b1),.expected_device(expected_device),.proposed_config(held_config),
        .result_valid(cfg_result),.result_ready(state==CFG_WAIT),.result_error(cfg_error),
        .store_error_detail(cfg_store_error),.config_known(cfg_known),.active_config(cfg_active),
        .config_generation(cfg_generation),.store_cmd_valid(cfg_valid),.store_cmd_ready(ds_ready && done && cfg_write),
        .store_cmd(cfg_cmd),.store_device(cfg_device),.store_config(cfg_data),
        .store_result_valid(ds_valid && done && cfg_write),.store_result_ready(cfg_rsp_ready),
        .store_error(ds_error),.store_loaded(ds_loaded),.store_device_id(ds_device),
        .store_generation(generation),.store_boot(ds_boot),.store_stored_config(ds_config));
    wire [1:0] c_valid,c_ready,c_rsp_valid,c_rsp_ready;
    wire [13:0] c_device;wire [3:0] c_addr_bytes,c_error;
    wire [31:0] c_address;wire [11:0] c_wr_count,c_rd_count;wire [511:0] c_wr_data,c_rd_data;
    eeprom_dualslot_store #(.MAX_POLLS(MAX_POLLS)) store(.clk(clk),.rst(rst),
        .cmd_valid(!done?gate_valid:(cfg_write && cfg_valid)),.cmd_ready(ds_ready),
        .cmd(!done?gate_cmd:cfg_cmd),.expected_device(!done?gate_device:cfg_device),
        .config_data(!done?gate_config:cfg_data),.result_valid(ds_valid),
        .result_ready(!done?gate_rsp_ready:(cfg_write && cfg_rsp_ready)),.result_error(ds_error),.loaded(ds_loaded),
        .active_slot(active_slot),.device_id(ds_device),.generation(generation),.boot_id(ds_boot),.stored_config(ds_config),
        .bus_req_valid(c_valid[0]),.bus_req_ready(c_ready[0]),.bus_device(c_device[6:0]),.bus_addr_bytes(c_addr_bytes[1:0]),
        .bus_address(c_address[15:0]),.bus_wr_count(c_wr_count[5:0]),.bus_rd_count(c_rd_count[5:0]),.bus_wr_data(c_wr_data[255:0]),
        .bus_rsp_valid(c_rsp_valid[0]),.bus_rsp_ready(c_rsp_ready[0]),.bus_error(c_error[1:0]),.bus_rd_data(c_rd_data[255:0]));
    wire boot_config_valid;
    persistent_config_decode boot_decode(.config_data(ds_config),.valid(boot_config_valid),.legacy_defaults(),
        .seat_id(),.exam_duration_s(),.rtc_offset_known(),.rtc_offset_minutes(),.mute());

    wire setter_ready,setter_result,setter_attempted,s_req,s_rsp_ready;
    reg refresh_pending,anchor_inflight,clock_invalidated;
    reg [31:0] refresh_timer;
    wire refresh_ready,anchor_known,anchor_fresh;
    wire refresh_valid=admission && boot_published && state==IDLE && !request_valid && refresh_pending && !anchor_inflight;
    wire a_req,a_rsp_ready;wire [6:0] a_device;wire [1:0] a_addr_bytes;
    wire [15:0] a_address;wire [5:0] a_wc,a_rc;wire [255:0] a_data;
    wire setter_mode=state==RTC_START || state==RTC_WAIT;
    rtc_anchor_client #(.STALE_CYCLES(RTC_STALE_CYCLES),.MAX_READ_CYCLES(RTC_MAX_READ_CYCLES)) anchor(
        .clk(clk),.rst(rst),.boot_admission(admission),.device_id(expected_device),.boot_id(boot_id),.monotonic_ms(monotonic_ms),
        .refresh_valid(refresh_valid),.refresh_ready(refresh_ready),.known(anchor_known),.fresh(anchor_fresh),.age_cycles(rtc_age_cycles),
        .byte_valid(byte_valid),.byte_last(byte_last),.byte_data(byte_data),.byte_ready(byte_ready),
        .bus_req_valid(a_req),.bus_req_ready(c_ready[1] && !setter_mode),.bus_device(a_device),.bus_addr_bytes(a_addr_bytes),
        .bus_address(a_address),.bus_wr_count(a_wc),.bus_rd_count(a_rc),.bus_wr_data(a_data),
        .bus_rsp_valid(c_rsp_valid[1] && !setter_mode),.bus_rsp_ready(a_rsp_ready),
        .bus_error(c_error[3:2]),.bus_rd_data(c_rd_data[511:256]));
    assign rtc_known=anchor_known && !clock_invalidated;
    assign rtc_fresh=anchor_fresh && !clock_invalidated;
    always @(posedge clk) begin
        if(rst) begin refresh_pending<=1;refresh_timer<=0;anchor_inflight<=0;clock_invalidated<=0;end
        else begin
            if(refresh_valid && refresh_ready) begin anchor_inflight<=1;refresh_pending<=0;refresh_timer<=0;end
            else if(!refresh_pending && state==IDLE) begin
                if(refresh_timer==REFRESH_CYCLES-1) begin refresh_pending<=1;refresh_timer<=0;end
                else refresh_timer<=refresh_timer+1'b1;
            end
            if(byte_valid && byte_ready && byte_last) begin anchor_inflight<=0;clock_invalidated<=0;end
            if(state==RTC_START) clock_invalidated<=1;
            if(state==RTC_WAIT && setter_result) begin refresh_pending<=1;refresh_timer<=0;end
        end
    end
    wire [3:0] setter_error;wire [1:0] setter_recovery;
    wire [71:0] setter_snapshot;wire [6:0] s_device;wire [1:0] s_addr_bytes;
    wire [15:0] s_address;wire [5:0] s_wc,s_rc;wire [255:0] s_data;
    pcf8563_setter #(.MAX_READ_CYCLES(RTC_MAX_READ_CYCLES)) setter(.clk(clk),.rst(rst),
        .set_valid(state==RTC_START),.set_ready(setter_ready),.maintenance(1'b1),.authorize(1'b1),.calendar_data(held_calendar),
        .result_valid(setter_result),.result_ready(state==RTC_WAIT),.result_error(setter_error),
        .recovery_error(setter_recovery),.write_attempted(setter_attempted),.snapshot(setter_snapshot),
        .bus_req_valid(s_req),.bus_req_ready(c_ready[1] && setter_mode),.bus_device(s_device),.bus_addr_bytes(s_addr_bytes),
        .bus_address(s_address),.bus_wr_count(s_wc),.bus_rd_count(s_rc),.bus_wr_data(s_data),
        .bus_rsp_valid(c_rsp_valid[1] && setter_mode),.bus_rsp_ready(s_rsp_ready),
        .bus_error(c_error[3:2]),.bus_rd_data(c_rd_data[511:256]));
    assign c_valid[1]=setter_mode?s_req:a_req;
    assign c_rsp_ready[1]=setter_mode?s_rsp_ready:a_rsp_ready;
    assign c_device[13:7]=setter_mode?s_device:a_device;
    assign c_addr_bytes[3:2]=setter_mode?s_addr_bytes:a_addr_bytes;
    assign c_address[31:16]=setter_mode?s_address:a_address;
    assign c_wr_count[11:6]=setter_mode?s_wc:a_wc;
    assign c_rd_count[11:6]=setter_mode?s_rc:a_rc;
    assign c_wr_data[511:256]=setter_mode?s_data:a_data;
    wire req_valid,req_ready,rsp_valid,rsp_ready;
    wire [6:0] bus_device;wire [1:0] addr_bytes,bus_error;
    wire [15:0] address;wire [5:0] wr_count,rd_count;wire [255:0] wr_data,rd_data;
    i2c_transaction_arbiter arbiter(.clk(clk),.rst(rst),
        .s_req_valid(c_valid),.s_req_ready(c_ready),.s_device(c_device),.s_addr_bytes(c_addr_bytes),
        .s_address(c_address),.s_wr_count(c_wr_count),.s_rd_count(c_rd_count),.s_wr_data(c_wr_data),
        .s_rsp_valid(c_rsp_valid),.s_rsp_ready(c_rsp_ready),.s_error(c_error),.s_rd_data(c_rd_data),
        .m_req_valid(req_valid),.m_req_ready(req_ready),.m_device(bus_device),.m_addr_bytes(addr_bytes),
        .m_address(address),.m_wr_count(wr_count),.m_rd_count(rd_count),.m_wr_data(wr_data),
        .m_rsp_valid(rsp_valid),.m_rsp_ready(rsp_ready),.m_error(bus_error),.m_rd_data(rd_data),
        .busy(),.owner(),.next_owner(),.grants(),.completed());
    i2c_register_master #(.QUARTER_CYCLES(QUARTER_CYCLES),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) master(
        .clk(clk),.rst(rst),.req_valid(req_valid),.req_ready(req_ready),.req_device(bus_device),.req_addr_bytes(addr_bytes),
        .req_address(address),.req_wr_count(wr_count),.req_rd_count(rd_count),.req_wr_data(wr_data),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_error(bus_error),.rsp_rd_data(rd_data),
        .scl_i(scl_i),.sda_i(sda_i),.scl_low(scl_low),.sda_low(sda_low));

    assign request_ready=!rst && done && boot_published && state==IDLE && !result_valid;
    assign maintenance_busy=state!=IDLE || (request_valid && request_ready && maintenance_allowed && admission && opcode<=2);
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;held_config<=0;held_calendar<=0;result_valid<=0;result_opcode<=0;
            result_error<=0;result_detail<=0;result_store_error<=0;result_recovery_error<=0;result_write_attempted<=0;result_snapshot<=0;
            config_write_attempted<=0;
            config_known<=0;active_config<=0;config_generation<=0;boot_published<=0;
        end else begin
            if(cfg_write && c_valid[0] && c_ready[0] && c_wr_count[5:0]!=0) config_write_attempted<=1;
            if(done && !boot_published) begin
                boot_published<=1;
                if(admission && boot_config_valid) begin config_known<=1;active_config<=ds_config;config_generation<=generation;end
            end
            if(result_valid && result_ready) begin result_valid<=0;if(state==HOLD) state<=IDLE;end
            case(state)
                IDLE:if(request_valid && request_ready) begin
                    result_opcode<=opcode;result_detail<=0;result_store_error<=0;result_recovery_error<=0;
                    config_write_attempted<=0;
                    result_write_attempted<=0;result_snapshot<=0;result_error<=0;
                    if(!admission || !maintenance_allowed) begin result_error<=1;result_valid<=1;state<=HOLD;end
                    else if(opcode>2) begin result_error<=2;result_valid<=1;state<=HOLD;end
                    else begin held_config<=proposed_config;held_calendar<=calendar_data;state<=DRAIN;end
                end
                DRAIN:if(!anchor_inflight) state<=result_opcode==2?RTC_START:CFG_START;
                CFG_START:if(cfg_ready) state<=CFG_WAIT;
                CFG_WAIT:if(cfg_result) begin
                    if(cfg_error!=0) begin result_error<=3;result_detail<=cfg_error;end
                    else begin config_known<=cfg_known;active_config<=cfg_active;config_generation<=cfg_generation;end
                    result_recovery_error<=0;result_write_attempted<=config_write_attempted;
                    result_store_error<=cfg_store_error;result_snapshot<=0;result_valid<=1;state<=HOLD;
                end
                RTC_START:if(setter_ready) state<=RTC_WAIT;
                RTC_WAIT:if(setter_result) begin
                    result_error<=setter_error==0?0:4;result_detail<=setter_error;
                    result_recovery_error<=setter_recovery;result_write_attempted<=setter_attempted;
                    result_snapshot<=setter_snapshot;result_valid<=1;state<=HOLD;
                end
            endcase
        end
    end
endmodule
