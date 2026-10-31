`timescale 1ns/1ps
// Read-only RTC anchor. The calendar second is bracketed by source-domain
// monotonic times at refresh acceptance/result publication, never substituted
// for event time. Whole request interval includes arbiter wait and reread.
// Result fields held during backpressure. Common reset with reader/master.
module rtc_time_anchor #(
    parameter [31:0] STALE_CYCLES=100000000,MAX_READ_CYCLES=25000000
)(
    input wire clk,rst,
    input wire boot_admission,input wire [31:0] device_id,boot_id,
    input wire [63:0] monotonic_ms,
    input wire refresh_valid,output wire refresh_ready,
    output reg result_valid,input wire result_ready,
    output reg [2:0] result_error,
    output reg [31:0] anchor_device,anchor_boot,anchor_sequence,
    output reg [63:0] lower_ms,upper_ms,
    output reg [71:0] rtc_raw,
    output reg known,output wire fresh,output reg [31:0] age_cycles,
    output wire bus_req_valid,input wire bus_req_ready,
    output wire [6:0] bus_device,output wire [1:0] bus_addr_bytes,
    output wire [15:0] bus_address,output wire [5:0] bus_wr_count,bus_rd_count,
    output wire [255:0] bus_wr_data,
    input wire bus_rsp_valid,output wire bus_rsp_ready,
    input wire [1:0] bus_error,input wire [255:0] bus_rd_data
);
    reg busy;
    reg [31:0] held_device,held_boot;
    reg [63:0] started_ms;
    wire reader_ready,reader_valid,reader_known;
    wire [1:0] reader_error;
    wire [71:0] reader_raw;
    wire admission=boot_admission && device_id!=0 && boot_id!=0;
    assign refresh_ready=!rst && !busy && !result_valid && admission && reader_ready && anchor_sequence!=32'hffffffff;
    assign fresh=known && age_cycles<=STALE_CYCLES && admission &&
        anchor_device==device_id && anchor_boot==boot_id;
    pcf8563_reader #(.STALE_CYCLES(STALE_CYCLES),.MAX_READ_CYCLES(MAX_READ_CYCLES)) reader(
        .clk(clk),.rst(rst),.refresh_valid(refresh_valid && refresh_ready),.refresh_ready(reader_ready),
        .result_valid(reader_valid),.result_ready(busy && !result_valid),.result_error(reader_error),
        .snapshot(reader_raw),.known(reader_known),.fresh(),.age_cycles(),
        .year(),.month(),.day(),.hour(),.minute(),.second(),.weekday(),
        .bus_req_valid(bus_req_valid),.bus_req_ready(bus_req_ready),.bus_device(bus_device),.bus_addr_bytes(bus_addr_bytes),
        .bus_address(bus_address),.bus_wr_count(bus_wr_count),.bus_rd_count(bus_rd_count),.bus_wr_data(bus_wr_data),
        .bus_rsp_valid(bus_rsp_valid),.bus_rsp_ready(bus_rsp_ready),.bus_error(bus_error),.bus_rd_data(bus_rd_data));
    wire identity_changed=!admission || held_device!=device_id || held_boot!=boot_id;
    always @(posedge clk) begin
        if(rst) begin
            busy<=0;result_valid<=0;result_error<=0;known<=0;age_cycles<=32'hffffffff;
            held_device<=0;held_boot<=0;started_ms<=0;
            anchor_device<=0;anchor_boot<=0;anchor_sequence<=0;lower_ms<=0;upper_ms<=0;rtc_raw<=0;
        end else begin
            if(known && age_cycles!=32'hffffffff) age_cycles<=age_cycles+1'b1;
            if(result_valid && result_ready) result_valid<=0;
            if(refresh_valid && refresh_ready) begin
                busy<=1;held_device<=device_id;held_boot<=boot_id;started_ms<=monotonic_ms;
            end
            if(busy && reader_valid && !result_valid) begin
                busy<=0;result_valid<=1;
                anchor_device<=held_device;anchor_boot<=held_boot;
                lower_ms<=started_ms;upper_ms<=monotonic_ms;rtc_raw<=reader_raw;
                if(anchor_sequence!=32'hffffffff) anchor_sequence<=anchor_sequence+1'b1;
                age_cycles<=0;
                if(identity_changed || monotonic_ms<started_ms) begin result_error<=4;known<=0;end
                else if(reader_error!=0 || !reader_known) begin
                    result_error<=reader_error==0 ? 3'd2 : {1'b0,reader_error};known<=0;
                end else begin result_error<=0;known<=1;end
            end
        end
    end
endmodule
