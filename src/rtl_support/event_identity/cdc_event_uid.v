`timescale 1ns/1ps

// Toggle-based multi-bit bus crossing for the 64-bit event uid (src 50 MHz ->
// dst pixel clock). Original project implementation.
//
// The uid is latched into data_hold on each src_event and the toggle flips.
// The destination synchronises the toggle through two flops and, on an edge,
// captures data_hold and emits a one-cycle dst_event. data_hold is stable from
// the src_event until the toggle has propagated, so it is safe to sample.
//
// Events are exam-scale (milliseconds apart) and far slower than the ~2-3 dst
// clock synchroniser latency; an event that arrives inside that window can
// coalesce into the next one. That is acceptable for a best-effort identity
// stamp and is NOT used for alarm delivery. A caller that needs every event
// must also count src pulses separately.
module cdc_event_uid #(
    parameter integer WIDTH = 64
)(
    input                   clk_src,
    input                   rst_src,
    input                   src_event,
    input  [WIDTH-1:0]      src_uid,

    input                   clk_dst,
    input                   rst_dst,
    output reg [WIDTH-1:0]  dst_uid,
    output reg              dst_event
);
    reg [WIDTH-1:0] data_hold;
    reg             toggle;
    reg             toggle_sync1, toggle_sync2, toggle_prev;

    always @(posedge clk_src) begin
        if (rst_src) begin
            data_hold <= {WIDTH{1'b0}};
            toggle    <= 1'b0;
        end else if (src_event) begin
            data_hold <= src_uid;
            toggle    <= ~toggle;
        end
    end

    always @(posedge clk_dst) begin
        if (rst_dst) begin
            toggle_sync1 <= 1'b0;
            toggle_sync2 <= 1'b0;
            toggle_prev  <= 1'b0;
            dst_uid      <= {WIDTH{1'b0}};
            dst_event    <= 1'b0;
        end else begin
            toggle_sync1 <= toggle;
            toggle_sync2 <= toggle_sync1;
            dst_event    <= 1'b0;
            if (toggle_sync2 != toggle_prev) begin
                dst_uid   <= data_hold;
                dst_event <= 1'b1;
                toggle_prev <= toggle_sync2;
            end
        end
    end
endmodule
