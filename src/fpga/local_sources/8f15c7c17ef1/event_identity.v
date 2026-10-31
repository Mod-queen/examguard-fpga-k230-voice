`timescale 1ns / 1ps

// ExamGuard runtime identity boundary. Original project implementation.
//
// Produces the identity fields the transaction queue stamps onto every event:
// a static device_id, a boot_id, a per-exam session_id and a monotonic
// millisecond clock. This module does NOT persist across power loss: without
// the EEPROM/RTC (backlog C21) there is no non-volatile boot counter, so boot_id
// restarts at 1 on every FPGA configuration and only counts soft boots within
// that power cycle. session_id is unique only within one power cycle; use
// {boot_id, session_id} as the in-power identity and do not claim global
// uniqueness across power cycles.
//
// One ms_tick pulse is one millisecond. Every counter saturates, never wraps:
// a wrapped timestamp would make late events look earlier than the events they
// follow in an evidence log.
module event_identity #(
    parameter ID_WIDTH = 32
)(
    input wire clk,
    input wire rst,
    input wire ms_tick,
    input wire [ID_WIDTH-1:0] device_straps,
    input wire boot_pulse,
    input wire session_start,
    input wire session_end,
    output reg [ID_WIDTH-1:0] device_id,
    output reg [ID_WIDTH-1:0] boot_id,
    output reg [ID_WIDTH-1:0] session_id,
    output reg [63:0] time_ms,
    output reg session_active,
    output reg boot_event,
    output reg session_event,
    output wire [31:0] started_count,
    output wire [31:0] ignored_start_count
);
    localparam [ID_WIDTH-1:0] ID_MAX = {ID_WIDTH{1'b1}};
    localparam [63:0] TIME_MAX = {64{1'b1}};
    reg [31:0] started, ignored_start;
    // First active cycle after reset is the power-on boot (boot 1).
    reg boot_seen;

    assign started_count = started;
    assign ignored_start_count = ignored_start;

    always @(posedge clk) begin
        if (rst) begin
            device_id <= {ID_WIDTH{1'b0}};
            boot_id <= {ID_WIDTH{1'b0}};
            session_id <= {ID_WIDTH{1'b0}};
            time_ms <= 64'd0;
            session_active <= 1'b0;
            boot_event <= 1'b0;
            session_event <= 1'b0;
            started <= 32'd0;
            ignored_start <= 32'd0;
            boot_seen <= 1'b0;
        end else begin
            device_id <= device_straps;
            boot_event <= 1'b0;
            session_event <= 1'b0;

            // Monotonic clock: saturate, never wrap.
            if (ms_tick && time_ms != TIME_MAX)
                time_ms <= time_ms + 64'd1;

            // Boot: the first run after reset, or an explicit soft reboot.
            if (!boot_seen) begin
                boot_seen <= 1'b1;
                if (boot_id != ID_MAX) boot_id <= boot_id + {{(ID_WIDTH-1){1'b0}}, 1'b1};
                boot_event <= 1'b1;
            end else if (boot_pulse) begin
                if (boot_id != ID_MAX) boot_id <= boot_id + {{(ID_WIDTH-1){1'b0}}, 1'b1};
                boot_event <= 1'b1;
            end

            // Exam session: one start per session; end makes the next start legal.
            if (session_start) begin
                if (session_active) begin
                    if (ignored_start != 32'hffffffff) ignored_start <= ignored_start + 32'd1;
                end else begin
                    session_active <= 1'b1;
                    session_event <= 1'b1;
                    if (session_id != ID_MAX) session_id <= session_id + {{(ID_WIDTH-1){1'b0}}, 1'b1};
                    if (started != 32'hffffffff) started <= started + 32'd1;
                end
            end else if (session_end) begin
                session_active <= 1'b0;
            end
        end
    end
endmodule
