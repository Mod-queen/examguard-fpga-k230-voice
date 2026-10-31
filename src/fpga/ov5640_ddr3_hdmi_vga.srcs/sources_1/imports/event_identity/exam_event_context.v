`timescale 1ns/1ps
// Same-clock adapter for REGISTERED exam_fsm requests. At edge T the FSM
// observes time_ms(T), emits request/stage via NBA; at T+1 this module sees the
// request, captures the T time sample and the correct session; queue takes it
// at T+2. Session starts from LOCAL FSM stage, never pixel/status round-trip.
// S3 emits no event. A submit collision's EXAM and SUBMITTED lanes all keep the
// session being closed. Lane stages are immutable diagnostics, not session IDs.
// Connect session_start/end to event_identity in the SAME clock/reset domain.
module exam_event_context(
    input wire clk,rst,
    input wire [2:0] stage,
    input wire [3:0] request,
    input wire [63:0] request_data,
    input wire [31:0] device_id,boot_id,session_id,
    input wire session_active,
    input wire [63:0] time_ms,
    output wire session_start,session_end,
    output reg [3:0] aligned_request,
    output reg [63:0] aligned_data,aligned_time_ms,
    output reg [31:0] aligned_device,aligned_boot,aligned_session
);
    reg [2:0] previous_stage;
    reg [63:0] previous_time_ms;
    assign session_start=!rst && stage==3 && previous_stage!=3;
    assign session_end=!rst && previous_stage==3 && stage!=3;
    always @(posedge clk) begin
        if(rst) begin
            previous_stage<=0;previous_time_ms<=0;
            aligned_request<=0;aligned_data<=0;aligned_time_ms<=0;
            aligned_device<=0;aligned_boot<=0;aligned_session<=0;
        end else begin
            previous_stage<=stage;previous_time_ms<=time_ms;
            aligned_request<=request;aligned_data<=request_data;
            aligned_time_ms<=previous_time_ms;
            aligned_device<=device_id;aligned_boot<=boot_id;
            // Identity advances on this very edge; anticipate its new session
            // only for the start transition, never for SUBMITTED lane metadata.
            aligned_session<=session_start && !session_active && session_id!=32'hffffffff ? session_id+1'b1 : session_id;
        end
    end
endmodule
