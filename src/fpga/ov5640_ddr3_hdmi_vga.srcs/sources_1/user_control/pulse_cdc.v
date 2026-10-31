`timescale 1ns/1ps

// Single-cycle pulse crossing between asynchronous clock domains using a
// toggle handshake. Only the toggle bit crosses; the destination re-creates
// one pulse per source pulse and cannot drop or merge events.
module pulse_cdc (
    input  src_clk,
    input  src_rst,
    input  src_pulse,
    input  dst_clk,
    input  dst_rst,
    output dst_pulse
);

    reg src_toggle;

    (* ASYNC_REG = "TRUE" *) reg dst_meta;
    (* ASYNC_REG = "TRUE" *) reg dst_sync;
    reg dst_seen;

    always @(posedge src_clk) begin
        if (src_rst)
            src_toggle <= 1'b0;
        else if (src_pulse)
            src_toggle <= ~src_toggle;
    end

    always @(posedge dst_clk) begin
        if (dst_rst) begin
            dst_meta <= 1'b0;
            dst_sync <= 1'b0;
            dst_seen <= 1'b0;
        end else begin
            dst_meta <= src_toggle;
            dst_sync <= dst_meta;
            dst_seen <= dst_sync;
        end
    end

    assign dst_pulse = dst_sync ^ dst_seen;

endmodule
