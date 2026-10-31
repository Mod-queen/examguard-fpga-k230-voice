`timescale 1ns/1ps

// One-entry mailbox carrying a validated ROI request from the 50 MHz control
// domain into the pixel domain. The payload is held stable while only a toggle
// bit crosses, so the receiver always sees a coherent request.
module config_mailbox (
    input             src_clk,
    input             src_rst,
    input             src_valid,
    input      [7:0]  src_version,
    input      [1:0]  src_region,
    input      [11:0] src_x0,
    input      [11:0] src_y0,
    input      [11:0] src_x1,
    input      [11:0] src_y1,
    input      [7:0]  src_thr,
    input             dst_clk,
    input             dst_rst,
    output reg        dst_valid,
    output reg [7:0]  dst_version,
    output reg [1:0]  dst_region,
    output reg [11:0] dst_x0,
    output reg [11:0] dst_y0,
    output reg [11:0] dst_x1,
    output reg [11:0] dst_y1,
    output reg [7:0]  dst_thr
);

    reg [7:0]  src_version_reg;
    reg [1:0]  src_region_reg;
    reg [11:0] src_x0_reg;
    reg [11:0] src_y0_reg;
    reg [11:0] src_x1_reg;
    reg [11:0] src_y1_reg;
    reg [7:0]  src_thr_reg;
    reg        src_toggle;

    (* ASYNC_REG = "TRUE" *) reg dst_toggle_meta;
    (* ASYNC_REG = "TRUE" *) reg dst_toggle_sync;
    reg dst_toggle_seen;

    always @(posedge src_clk) begin
        if (src_rst) begin
            src_version_reg <= 8'd0;
            src_region_reg  <= 2'd0;
            src_x0_reg      <= 12'd0;
            src_y0_reg      <= 12'd0;
            src_x1_reg      <= 12'd0;
            src_y1_reg      <= 12'd0;
            src_thr_reg     <= 8'd0;
            src_toggle      <= 1'b0;
        end else if (src_valid) begin
            src_version_reg <= src_version;
            src_region_reg  <= src_region;
            src_x0_reg      <= src_x0;
            src_y0_reg      <= src_y0;
            src_x1_reg      <= src_x1;
            src_y1_reg      <= src_y1;
            src_thr_reg     <= src_thr;
            src_toggle      <= ~src_toggle;
        end
    end

    always @(posedge dst_clk) begin
        if (dst_rst) begin
            dst_toggle_meta <= 1'b0;
            dst_toggle_sync <= 1'b0;
            dst_toggle_seen <= 1'b0;
            dst_valid       <= 1'b0;
            dst_version     <= 8'd0;
            dst_region      <= 2'd0;
            dst_x0          <= 12'd0;
            dst_y0          <= 12'd0;
            dst_x1          <= 12'd0;
            dst_y1          <= 12'd0;
            dst_thr         <= 8'd0;
        end else begin
            dst_toggle_meta <= src_toggle;
            dst_toggle_sync <= dst_toggle_meta;
            dst_valid       <= 1'b0;

            if (dst_toggle_sync != dst_toggle_seen) begin
                dst_toggle_seen <= dst_toggle_sync;
                dst_version     <= src_version_reg;
                dst_region      <= src_region_reg;
                dst_x0          <= src_x0_reg;
                dst_y0          <= src_y0_reg;
                dst_x1          <= src_x1_reg;
                dst_y1          <= src_y1_reg;
                dst_thr         <= src_thr_reg;
                dst_valid       <= 1'b1;
            end
        end
    end

endmodule
