`timescale 1ns/1ps
////////////////////////////////////////////////////////////////////////////////////
// cdc_exam_status - 50 MHz -> pixel transfer of exam stage/risk/event.
//
// The source toggles whenever the packed status changes; the fields are held
// stable for many pixel clocks, so the destination can capture them safely on
// the synchronised toggle edge.
////////////////////////////////////////////////////////////////////////////////////
module cdc_exam_status (
    input             src_clk,
    input             src_rst,
    input      [2:0]  src_stage,
    input      [1:0]  src_risk,
    input      [7:0]  src_event,

    input             dst_clk,
    input             dst_rst,
    output reg [2:0]  dst_stage,
    output reg [1:0]  dst_risk,
    output reg [7:0]  dst_event
);

    wire [12:0] src_now = {src_stage, src_risk, src_event};

    reg         src_toggle;
    reg  [12:0] src_hold;

    always @(posedge src_clk) begin
        if (src_rst) begin
            src_toggle <= 1'b0;
            src_hold   <= 13'd0;
        end else if (src_now != src_hold) begin
            src_hold   <= src_now;
            src_toggle <= ~src_toggle;
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
            dst_stage <= 3'd0;
            dst_risk  <= 2'd0;
            dst_event <= 8'd0;
        end else if (dst_edge) begin
            dst_stage <= src_hold[12:10];
            dst_risk  <= src_hold[9:8];
            dst_event <= src_hold[7:0];
        end
    end

endmodule
