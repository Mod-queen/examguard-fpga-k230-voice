`timescale 1ns/1ps
// Runtime identity that survives transport-only cancellation. Every new transport
// epoch increments boot BEFORE requests are admitted, so a reset source queue's
// UID1 cannot collide with an older epoch's UID1. Power/configuration still
// restarts boot; this is not nonvolatile uniqueness. session/time survive a
// transport reset. system_rst resets the whole identity (FPGA reset contract).
module evidence_epoch_identity #(
    parameter [31:0] BOOT_MAX=32'hffffffff
)(
    input wire clk,system_rst,transport_rst,ms_tick,session_start,session_end,
    input wire [31:0] device_straps,
    output wire [31:0] device_id,boot_id,session_id,
    output wire [63:0] time_ms,
    output wire session_active,
    output wire request_rst,
    output wire request_enable,
    output reg boot_exhausted
);
    (* ASYNC_REG="TRUE" *) reg [2:0] startup;
    reg boot_pending;
    reg source_open;
    always @(posedge clk or posedge transport_rst) begin
        if(transport_rst) begin startup<=3'b111;boot_pending<=1;end
        else begin startup<={startup[1:0],1'b0};boot_pending<=0;end
    end
    // The epoch at BOOT_MAX is usable. A further restart cannot allocate a new
    // boot, so latch exhausted and stop admission until whole-system reset.
    always @(posedge clk) begin
        if(system_rst) boot_exhausted<=0;
        else if(boot_pending && !transport_rst && boot_id>=BOOT_MAX) boot_exhausted<=1;
        if(request_rst) source_open<=0;else source_open<=1;
    end
    assign request_rst=system_rst || transport_rst || startup[2] || boot_exhausted;
    // Registered FSM request at edge T+1 belongs to T. Require BOTH T and T+1
    // admission open; otherwise a pulse born during cancellation can leak when
    // queue reset deasserts. Context stage/time tracking itself remains alive.
    assign request_enable=!request_rst && source_open;
    event_identity identity(.clk(clk),.rst(system_rst),.ms_tick(ms_tick),.device_straps(device_straps),
        .boot_pulse(boot_pending && !transport_rst && boot_id<BOOT_MAX),.session_start(session_start),.session_end(session_end),
        .device_id(device_id),.boot_id(boot_id),.session_id(session_id),.time_ms(time_ms),.session_active(session_active),
        .boot_event(),.session_event(),.started_count(),.ignored_start_count());
endmodule
