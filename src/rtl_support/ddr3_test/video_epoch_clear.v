`timescale 1ns/1ps

// Bridge a camera/display-domain FIFO clear LEVEL (or pulse) to ui_clk.
// Async assertion catches pulses shorter than a UI cycle; release requires
// RELEASE_CYCLES clean UI edges and then lets the client sample one more edge.
// FIFO UI-side reset_busy is already a ui_clk signal and extends the hold.
// This only cancels a video LOCAL epoch. It is NOT the AXI/MIG common reset.
// All instantiated reset synchronizer flops are marked ASYNC_REG. Integration
// still needs targeted async reset recovery/removal constraints and CDC audit.
module video_epoch_clear #(
    parameter integer RELEASE_CYCLES=3
)(
    input wire ui_clk,
    input wire ui_rst,
    input wire source_clear,
    input wire fifo_ui_rst_busy,
    output wire client_clear
);
    (* ASYNC_REG="TRUE" *) reg [RELEASE_CYCLES-1:0] release_ff;
    wire assert_clear=source_clear || ui_rst;
    always @(posedge ui_clk or posedge assert_clear) begin
        if(assert_clear) release_ff<={RELEASE_CYCLES{1'b1}};
        else release_ff<=release_ff<<1;
    end
    assign client_clear=release_ff[RELEASE_CYCLES-1] || fifo_ui_rst_busy;
    // synthesis translate_off
    initial if(RELEASE_CYCLES<2) $fatal(1,"FAIL: epoch clear requires at least two stages");
    // synthesis translate_on
endmodule
