`timescale 1ns/1ps

// Dual-clock (asynchronous) FIFO with gray-coded pointers. Original project
// implementation (Cummings-style): each domain keeps its own binary+gray
// pointer; the other domain's gray pointer is synchronized with two flops.
// Registered full/empty flags. Used to move evidence data between the capture
// clock and the DDR/stream clock without a clock-domain glitch.
//
// DEPTH must be a power of two, >=4. Reset BOTH domains together; release each
// reset synchronously to its clock. Gray crossings require physical skew/delay
// constraints in the integrating project, in addition to these synchronizers.
module async_fifo #(
    parameter integer DATA_WIDTH = 16,
    parameter integer DEPTH      = 256,
    parameter RAM_STYLE = "auto"
)(
    input  wire                    wclk,
    input  wire                    wrst_n,
    input  wire                    winc,
    input  wire [DATA_WIDTH-1:0]   wdata,
    output reg                     wfull,

    input  wire                    rclk,
    input  wire                    rrst_n,
    input  wire                    rinc,
    output wire [DATA_WIDTH-1:0]   rdata,
    output reg                     rempty
);
    localparam integer AW = (DEPTH < 2) ? 1 : $clog2(DEPTH);

    (* ram_style = RAM_STYLE *) reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    reg [AW:0] wbin, wgray, rbin, rgray;
    (* ASYNC_REG = "TRUE" *) reg [AW:0] wq1_rgray, wq2_rgray; // rgray into wclk
    (* ASYNC_REG = "TRUE" *) reg [AW:0] rq1_wgray, rq2_wgray; // wgray into rclk

    // next pointers (advance only when not full/empty and enabled)
    wire [AW:0] wbin_next  = wbin + ((winc && !wfull) ? 1'b1 : 1'b0);
    wire [AW:0] wgray_next = (wbin_next >> 1) ^ wbin_next;
    wire [AW:0] rbin_next  = rbin + ((rinc && !rempty) ? 1'b1 : 1'b0);
    wire [AW:0] rgray_next = (rbin_next >> 1) ^ rbin_next;

    // full: next write gray equals the synced read gray with top two bits inverted
    wire wfull_val = (wgray_next == {~wq2_rgray[AW:AW-1], wq2_rgray[AW-2:0]});
    // empty: next read gray equals the synced write gray
    wire rempty_val = (rgray_next == rq2_wgray);

    assign rdata = mem[rbin[AW-1:0]];

    // Storage has NO asynchronous reset. Only the pointers/flags reset; stale
    // contents are unreachable while empty. Keep this outside the pointer
    // reset block so Vivado can infer dual-clock distributed RAM.
    always @(posedge wclk) begin
        if (wrst_n && winc && !wfull) mem[wbin[AW-1:0]] <= wdata;
    end

    // write domain
    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin <= {AW+1{1'b0}}; wgray <= {AW+1{1'b0}}; wfull <= 1'b0;
            wq1_rgray <= {AW+1{1'b0}}; wq2_rgray <= {AW+1{1'b0}};
        end else begin
            wbin  <= wbin_next;
            wgray <= wgray_next;
            wfull <= wfull_val;
            wq1_rgray <= rgray;
            wq2_rgray <= wq1_rgray;
        end
    end

    // read domain
    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin <= {AW+1{1'b0}}; rgray <= {AW+1{1'b0}}; rempty <= 1'b1;
            rq1_wgray <= {AW+1{1'b0}}; rq2_wgray <= {AW+1{1'b0}};
        end else begin
            rbin   <= rbin_next;
            rgray  <= rgray_next;
            rempty <= rempty_val;
            rq1_wgray <= wgray;
            rq2_wgray <= rq1_wgray;
        end
    end
endmodule
