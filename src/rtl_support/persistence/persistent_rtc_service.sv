`timescale 1ns/1ps
// System-domain boot allocation + periodic readonly RTC anchors, ONE master.
// Shared common reset. Transport/network cancellation is deliberately not an
// input. RTC starts only after boot verified; RTC failure never revokes boot.
module persistent_rtc_service #(
    parameter integer STARTUP_CYCLES=2500000,QUARTER_CYCLES=125,
    parameter integer TIMEOUT_CYCLES=500000,MAX_POLLS=128,
    parameter integer REFRESH_CYCLES=50000000,
    parameter [31:0] RTC_STALE_CYCLES=100000000,RTC_MAX_READ_CYCLES=25000000
)(
    input wire clk,rst,input wire [31:0] expected_device,
    input wire [63:0] monotonic_ms,
    input wire scl_i,sda_i,output wire scl_low,sda_low,
    output wire admission,done,output wire [3:0] error,
    output wire [31:0] boot_id,generation,output wire active_slot,
    output wire rtc_known,rtc_fresh,output wire [31:0] rtc_age_cycles,
    output wire byte_valid,byte_last,output wire [7:0] byte_data,input wire byte_ready
);
    reg [31:0] startup;
    reg started;
    wire start=!started && startup==STARTUP_CYCLES-1;
    always @(posedge clk) begin
        if(rst) begin startup<=0;started<=0;end
        else if(!started) begin
            if(start) started<=1;else startup<=startup+1'b1;
        end
    end
    wire cmd_valid,cmd_ready,result_valid,result_ready,loaded;
    wire [1:0] cmd;
    wire [31:0] requested_device,store_boot;
    wire [255:0] config_data;
    wire [3:0] store_error;
    persistent_boot_gate gate(.clk(clk),.rst(rst),.start(start),.format_blank(1'b0),
        .device(expected_device),.initial_config(256'd0),.store_cmd_valid(cmd_valid),.store_cmd_ready(cmd_ready),
        .store_cmd(cmd),.store_device(requested_device),.store_config(config_data),.store_result_valid(result_valid),
        .store_result_ready(result_ready),.store_error(store_error),.store_loaded(loaded),.store_boot(store_boot),
        .admission(admission),.done(done),.error(error),.boot_id(boot_id));
    wire [1:0] c_valid,c_ready,c_rsp_valid,c_rsp_ready;
    wire [13:0] c_device;wire [3:0] c_addr_bytes,c_error;
    wire [31:0] c_address;wire [11:0] c_wr_count,c_rd_count;
    wire [511:0] c_wr_data,c_rd_data;
    eeprom_dualslot_store #(.MAX_POLLS(MAX_POLLS)) store(.clk(clk),.rst(rst),
        .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd(cmd),.expected_device(requested_device),.config_data(config_data),
        .result_valid(result_valid),.result_ready(result_ready),.result_error(store_error),.loaded(loaded),
        .active_slot(active_slot),.device_id(),.generation(generation),.boot_id(store_boot),.stored_config(),
        .bus_req_valid(c_valid[0]),.bus_req_ready(c_ready[0]),.bus_device(c_device[6:0]),.bus_addr_bytes(c_addr_bytes[1:0]),
        .bus_address(c_address[15:0]),.bus_wr_count(c_wr_count[5:0]),.bus_rd_count(c_rd_count[5:0]),.bus_wr_data(c_wr_data[255:0]),
        .bus_rsp_valid(c_rsp_valid[0]),.bus_rsp_ready(c_rsp_ready[0]),.bus_error(c_error[1:0]),.bus_rd_data(c_rd_data[255:0]));
    reg refresh_pending;
    reg [31:0] refresh_timer;
    wire refresh_ready;
    // Coalesce periodic due times into ONE held request. Output backpressure
    // cannot queue an unbounded number of anchors or starve EEPROM polling.
    always @(posedge clk) begin
        if(rst || !admission) begin refresh_pending<=1;refresh_timer<=0;end
        else if(refresh_pending && refresh_ready) begin refresh_pending<=0;refresh_timer<=0;end
        else if(!refresh_pending) begin
            if(refresh_timer==REFRESH_CYCLES-1) begin refresh_pending<=1;refresh_timer<=0;end
            else refresh_timer<=refresh_timer+1'b1;
        end
    end
    rtc_anchor_client #(.STALE_CYCLES(RTC_STALE_CYCLES),.MAX_READ_CYCLES(RTC_MAX_READ_CYCLES)) rtc(
        .clk(clk),.rst(rst),.boot_admission(admission),.device_id(requested_device),.boot_id(boot_id),.monotonic_ms(monotonic_ms),
        .refresh_valid(admission && refresh_pending),.refresh_ready(refresh_ready),
        .known(rtc_known),.fresh(rtc_fresh),.age_cycles(rtc_age_cycles),
        .byte_valid(byte_valid),.byte_last(byte_last),.byte_data(byte_data),.byte_ready(byte_ready),
        .bus_req_valid(c_valid[1]),.bus_req_ready(c_ready[1]),.bus_device(c_device[13:7]),.bus_addr_bytes(c_addr_bytes[3:2]),
        .bus_address(c_address[31:16]),.bus_wr_count(c_wr_count[11:6]),.bus_rd_count(c_rd_count[11:6]),.bus_wr_data(c_wr_data[511:256]),
        .bus_rsp_valid(c_rsp_valid[1]),.bus_rsp_ready(c_rsp_ready[1]),.bus_error(c_error[3:2]),.bus_rd_data(c_rd_data[511:256]));
    wire req_valid,req_ready,rsp_valid,rsp_ready;
    wire [6:0] bus_device;wire [1:0] addr_bytes,bus_error;
    wire [15:0] address;wire [5:0] wr_count,rd_count;
    wire [255:0] wr_data,rd_data;
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
endmodule
