`timescale 1ns/1ps
// Read-only 50MHz report assembly. Source-domain buses transferred atomically;
// reported flags state whether each cached bus belongs to a fresh CURRENT
// transport epoch. Source counters are per epoch; cancel_epochs and blocked
// FSM requests live until system reset. Cancellation counts epochs, NOT lost
// events inferred by subtracting asynchronous counters.
module evidence_health_telemetry #(
    parameter [31:0] STALE_CYCLES=32'd25000000,
    parameter integer ENABLE_PHY_HEALTH=0
)(
    input wire clk,system_rst,control_rst,cap_clk,cap_rst,ui_clk,ui_rst,eth_clk,eth_rst,
    input wire [31:0] device_id,boot_id,session_id,
    input wire [63:0] time_ms,
    input wire boot_exhausted,id_exhausted,request_enable,
    input wire [3:0] fsm_requests,source_occupancy,source_high_water,
    input wire [31:0] source_accepted,source_rejected,source_delivered,
    input wire [255:0] cap_stats,ui_stats,
    input wire [127:0] eth_stats,
    input wire [31:0] phy_summary, // coherent control-domain summary, independent of transport reset
    output wire [1023:0] report_data,
    output wire [23:0] flags,
    output reg [31:0] cancel_epochs,blocked_requests
);
    wire [255:0] cap_copy,ui_copy;
    wire [127:0] eth_copy;
    wire cap_valid,ui_valid,eth_valid;
    wire [31:0] cap_age,ui_age,eth_age;
    cdc_stats_snapshot cap_snapshot(.src_clk(cap_clk),.src_rst(cap_rst),.src_stats(cap_stats),
        .dst_clk(clk),.dst_rst(control_rst),.stats(cap_copy),.valid(cap_valid),.age_cycles(cap_age));
    cdc_stats_snapshot ui_snapshot(.src_clk(ui_clk),.src_rst(ui_rst),.src_stats(ui_stats),
        .dst_clk(clk),.dst_rst(control_rst),.stats(ui_copy),.valid(ui_valid),.age_cycles(ui_age));
    cdc_stats_snapshot #(.WIDTH(128)) eth_snapshot(.src_clk(eth_clk),.src_rst(eth_rst),.src_stats(eth_stats),
        .dst_clk(clk),.dst_rst(control_rst),.stats(eth_copy),.valid(eth_valid),.age_cycles(eth_age));
    reg was_reset,ever_open;
    integer blocked;
    always @* blocked=fsm_requests[0]+{1'b0,fsm_requests[1]}+{1'b0,fsm_requests[2]}+{1'b0,fsm_requests[3]};
    always @(posedge clk) begin
        if(system_rst) begin cancel_epochs<=0;blocked_requests<=0;was_reset<=1;ever_open<=0;end
        else begin
            was_reset<=control_rst;
            if(!control_rst) ever_open<=1;
            if(control_rst && !was_reset && ever_open && cancel_epochs!=32'hffffffff) cancel_epochs<=cancel_epochs+1'b1;
            if(!request_enable) begin
                if(32'hffffffff-blocked_requests<blocked) blocked_requests<=32'hffffffff;
                else blocked_requests<=blocked_requests+blocked;
            end
        end
    end
    wire cap_fresh=!control_rst && cap_valid && cap_age<=STALE_CYCLES;
    wire ui_fresh=!control_rst && ui_valid && ui_age<=STALE_CYCLES;
    wire eth_fresh=!control_rst && eth_valid && eth_age<=STALE_CYCLES;
    assign flags={8'd0,
        (ui_fresh && ui_copy[255]),                       // 15 UI busy
        (eth_fresh && eth_copy[96]),                      // 14 packet ingress stall
        (eth_fresh && (eth_copy[97] || eth_copy[63:32]!=0)),// 13 UDP fault/drop
        (ui_fresh && ui_copy[254]),                       // 12 packet fault
        (ui_fresh && (ui_copy[127:96]!=0 || ui_copy[95:64]!=0 || ui_copy[63:32]!=0)), //11 framefail/readerr/windowfail
        (cap_fresh && (cap_copy[159:128]!=0 || cap_copy[127:96]!=0)), //10 busy/invalid drop
        (!control_rst && eth_valid && !eth_fresh),        //9 eth stale
        (!control_rst && ui_valid && !ui_fresh),          //8 UI stale
        (!control_rst && cap_valid && !cap_fresh),        //7 cap stale
        eth_fresh,ui_fresh,cap_fresh,                     //6/5/4 freshness
        (source_occupancy==8),id_exhausted,boot_exhausted,control_rst};
    // Avoid presenting cached values as live during cancellation or staleness.
    // flags explicitly retain unknown/stale diagnosis; no fake zero-healthy.
    assign report_data={(ENABLE_PHY_HEALTH?8'd2:8'd1),flags,device_id,boot_id,session_id,
        (control_rst ? 32'd0 : source_accepted),(control_rst ? 32'd0 : source_rejected),(control_rst ? 32'd0 : source_delivered),
        24'd0,source_high_water,source_occupancy,cancel_epochs,blocked_requests,time_ms,
        (cap_fresh ? cap_copy : 256'd0),(ui_fresh ? ui_copy : 256'd0),(eth_fresh ? eth_copy[127:32] : 96'd0),
        (ENABLE_PHY_HEALTH ? phy_summary : 32'd0)};
endmodule
