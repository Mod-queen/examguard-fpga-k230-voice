`timescale 1ns/1ps
////////////////////////////////////////////////////////////////////////////////////
// cdc_frame_activity - pixel -> 50 MHz transfer of the per-frame activity score.
//
// Source latches activity/cells and toggles once per frame (~16 ms at 720p60),
// far slower than the destination synchroniser latency, so the held data is
// stable while the destination captures it on the toggle edge.
////////////////////////////////////////////////////////////////////////////////////
module cdc_frame_activity (
    input             src_clk,
    input             src_rst,
    input             src_frame,      // one-cycle pulse per frame (pixel domain)
    input      [7:0]  src_activity,
    input      [15:0] src_cells,
    input      [7:0]  src_luma,

    input             dst_clk,
    input             dst_rst,
    output            dst_pulse,      // one dst cycle when a new frame arrives
    output reg [7:0]  dst_activity,
    output reg [15:0] dst_cells,
    output reg [7:0]  dst_luma
);

    reg        src_toggle;
    reg [7:0]  src_activity_hold;
    reg [15:0] src_cells_hold;
    reg [7:0]  src_luma_hold;

    always @(posedge src_clk) begin
        if (src_rst) begin
            src_toggle        <= 1'b0;
            src_activity_hold <= 8'd0;
            src_cells_hold    <= 16'd0;
            src_luma_hold     <= 8'd0;
        end else if (src_frame) begin
            src_toggle        <= ~src_toggle;
            src_activity_hold <= src_activity;
            src_cells_hold    <= src_cells;
            src_luma_hold     <= src_luma;
        end
    end

    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [2:0] dst_sync;
    always @(posedge dst_clk) begin
        if (dst_rst)
            dst_sync <= 3'b000;
        else
            dst_sync <= {dst_sync[1:0], src_toggle};
    end

    wire dst_edge = dst_sync[2] ^ dst_sync[1];

    always @(posedge dst_clk) begin
        if (dst_rst) begin
            dst_activity <= 8'd0;
            dst_cells    <= 16'd0;
            dst_luma     <= 8'd0;
        end else if (dst_edge) begin
            dst_activity <= src_activity_hold;
            dst_cells    <= src_cells_hold;
            dst_luma     <= src_luma_hold;
        end
    end

    assign dst_pulse = dst_edge;

endmodule
