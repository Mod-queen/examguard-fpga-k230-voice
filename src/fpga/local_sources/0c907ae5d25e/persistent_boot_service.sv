`timescale 1ns/1ps
// Main-system service: one verified NEXT_BOOT per system reset. Never formats.
// No transport reset input: network/history cancellation must not wear EEPROM.
module persistent_boot_service #(
    parameter integer STARTUP_CYCLES=2500000,QUARTER_CYCLES=125,
    parameter integer TIMEOUT_CYCLES=500000,MAX_POLLS=128
)(
    input wire clk,rst,input wire [31:0] expected_device,
    input wire scl_i,sda_i,output wire scl_low,sda_low,
    output wire admission,done,output wire [3:0] error,
    output wire [31:0] boot_id,generation,output wire active_slot
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
    wire [31:0] device,store_device,store_boot;
    wire [255:0] config_data;
    wire [3:0] store_error;
    persistent_boot_gate gate(.clk(clk),.rst(rst),.start(start),.format_blank(1'b0),
        .device(expected_device),.initial_config(256'd0),.store_cmd_valid(cmd_valid),.store_cmd_ready(cmd_ready),
        .store_cmd(cmd),.store_device(device),.store_config(config_data),.store_result_valid(result_valid),
        .store_result_ready(result_ready),.store_error(store_error),.store_loaded(loaded),.store_boot(store_boot),
        .admission(admission),.done(done),.error(error),.boot_id(boot_id));
    wire req_valid,req_ready,rsp_valid,rsp_ready;
    wire [6:0] bus_device;wire [1:0] addr_bytes,bus_error;
    wire [15:0] address;wire [5:0] wr_count,rd_count;
    wire [255:0] wr_data,rd_data;
    eeprom_dualslot_store #(.MAX_POLLS(MAX_POLLS)) store(.clk(clk),.rst(rst),
        .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd(cmd),.expected_device(device),.config_data(config_data),
        .result_valid(result_valid),.result_ready(result_ready),.result_error(store_error),.loaded(loaded),
        .active_slot(active_slot),.device_id(store_device),.generation(generation),.boot_id(store_boot),.stored_config(),
        .bus_req_valid(req_valid),.bus_req_ready(req_ready),.bus_device(bus_device),.bus_addr_bytes(addr_bytes),
        .bus_address(address),.bus_wr_count(wr_count),.bus_rd_count(rd_count),.bus_wr_data(wr_data),
        .bus_rsp_valid(rsp_valid),.bus_rsp_ready(rsp_ready),.bus_error(bus_error),.bus_rd_data(rd_data));
    i2c_register_master #(.QUARTER_CYCLES(QUARTER_CYCLES),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) master(
        .clk(clk),.rst(rst),.req_valid(req_valid),.req_ready(req_ready),.req_device(bus_device),.req_addr_bytes(addr_bytes),
        .req_address(address),.req_wr_count(wr_count),.req_rd_count(rd_count),.req_wr_data(wr_data),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_error(bus_error),.rsp_rd_data(rd_data),
        .scl_i(scl_i),.sda_i(sda_i),.scl_low(scl_low),.sda_low(sda_low));
endmodule
