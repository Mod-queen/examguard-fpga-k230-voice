`timescale 1ns/1ps
// Candidate common reset + coherent time + SOF admission assembly. Outputs feed
// camera_evidence_client control_rst/cap_rst/rst, enable and frame_meta.
// arst MUST be the SAME cancellation that resets shared AXI arbiter/slave;
// SOF/display FIFO clears never assert it. cap_enable/frame_id/sof are cap-domain.
module evidence_capture_context #(
    parameter [31:0] MAX_AGE_CYCLES=32'd74250
)(
    input wire arst,control_clk,cap_clk,ui_clk,
    input wire [63:0] control_time_ms,
    input wire cap_enable,sof,
    input wire [31:0] frame_id,
    output wire control_rst,cap_rst,ui_rst,
    output wire frame_enable,
    output wire [95:0] frame_meta,
    output wire time_valid,
    output wire [63:0] time_ms,
    output wire [31:0] age_cycles,rejected_unknown,rejected_stale
);
    evidence_reset_epoch reset_epoch(.arst(arst),.control_clk(control_clk),.cap_clk(cap_clk),.ui_clk(ui_clk),
        .control_rst(control_rst),.cap_rst(cap_rst),.ui_rst(ui_rst));
    cdc_time_snapshot time_bridge(.src_clk(control_clk),.src_rst(control_rst),.src_time_ms(control_time_ms),
        .dst_clk(cap_clk),.dst_rst(cap_rst),.time_ms(time_ms),.time_valid(time_valid),.age_cycles(age_cycles));
    camera_time_guard #(.MAX_AGE_CYCLES(MAX_AGE_CYCLES)) frame_time(
        .clk(cap_clk),.rst(cap_rst),.sof(sof),.enable(cap_enable),.frame_id(frame_id),
        .time_ms(time_ms),.time_valid(time_valid),.age_cycles(age_cycles),.frame_enable(frame_enable),.frame_meta(frame_meta),
        .rejected_unknown(rejected_unknown),.rejected_stale(rejected_stale));
endmodule
