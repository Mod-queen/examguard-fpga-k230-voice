`timescale 1ns/1ps
// Read-only RTC bus client -> bracketed result -> immutable RA packet stream.
// Caller supplies same-domain monotonic time and qualified persistent boot.
// Connect to common transaction arbiter, not a second physical I2C master.
module rtc_anchor_client #(
    parameter [31:0] STALE_CYCLES=100000000,MAX_READ_CYCLES=25000000
)(
    input wire clk,rst,boot_admission,input wire [31:0] device_id,boot_id,
    input wire [63:0] monotonic_ms,
    input wire refresh_valid,output wire refresh_ready,
    output wire known,fresh,output wire [31:0] age_cycles,
    output wire byte_valid,byte_last,output wire [7:0] byte_data,input wire byte_ready,
    output wire bus_req_valid,input wire bus_req_ready,
    output wire [6:0] bus_device,output wire [1:0] bus_addr_bytes,
    output wire [15:0] bus_address,output wire [5:0] bus_wr_count,bus_rd_count,
    output wire [255:0] bus_wr_data,
    input wire bus_rsp_valid,output wire bus_rsp_ready,
    input wire [1:0] bus_error,input wire [255:0] bus_rd_data
);
    wire result_valid,result_ready;
    wire [2:0] result_error;
    wire [31:0] anchor_device,anchor_boot,anchor_sequence;
    wire [63:0] lower_ms,upper_ms;
    wire [71:0] rtc_raw;
    rtc_time_anchor #(.STALE_CYCLES(STALE_CYCLES),.MAX_READ_CYCLES(MAX_READ_CYCLES)) anchor(
        .clk(clk),.rst(rst),.boot_admission(boot_admission),.device_id(device_id),.boot_id(boot_id),.monotonic_ms(monotonic_ms),
        .refresh_valid(refresh_valid),.refresh_ready(refresh_ready),.result_valid(result_valid),.result_ready(result_ready),
        .result_error(result_error),.anchor_device(anchor_device),.anchor_boot(anchor_boot),.anchor_sequence(anchor_sequence),
        .lower_ms(lower_ms),.upper_ms(upper_ms),.rtc_raw(rtc_raw),.known(known),.fresh(fresh),.age_cycles(age_cycles),
        .bus_req_valid(bus_req_valid),.bus_req_ready(bus_req_ready),.bus_device(bus_device),.bus_addr_bytes(bus_addr_bytes),
        .bus_address(bus_address),.bus_wr_count(bus_wr_count),.bus_rd_count(bus_rd_count),.bus_wr_data(bus_wr_data),
        .bus_rsp_valid(bus_rsp_valid),.bus_rsp_ready(bus_rsp_ready),.bus_error(bus_error),.bus_rd_data(bus_rd_data));
    rtc_anchor_record record_inst(.clk(clk),.rst(rst),.result_valid(result_valid),.result_ready(result_ready),
        .result_error(result_error),.anchor_device(anchor_device),.anchor_boot(anchor_boot),.anchor_sequence(anchor_sequence),
        .lower_ms(lower_ms),.upper_ms(upper_ms),.rtc_raw(rtc_raw),
        .byte_valid(byte_valid),.byte_last(byte_last),.byte_data(byte_data),.byte_ready(byte_ready));
endmodule
