`timescale 1ns/1ps
// Coherent diagnostic summary, MDC falling-edge domain -> control clock.
// Reset owns ONLY this telemetry handshake, never shared video/AXI.
module phy_health_snapshot #(parameter [31:0] STALE_CYCLES=25000000)(
    input wire clk,mdc,arst,
    input wire status_valid,link_up,full_duplex,
    input wire [1:0] link_speed,
    input wire [31:0] phy_id,
    input wire [15:0] tx_delay_raw,rx_delay_raw,
    output wire [31:0] summary
);
    wire source_clk=~mdc;
    wire [1:0] resets;
    evidence_reset_barrier #(.DOMAINS(2)) barrier(.arst(arst),.clocks({clk,source_clk}),.resets(resets));
    wire [7:0] source_data={phy_id==32'h001cc916,status_valid,rx_delay_raw[3],tx_delay_raw[8],full_duplex,link_up,link_speed};
    wire [7:0] captured;
    wire valid;
    wire [31:0] age;
    cdc_stats_snapshot #(.WIDTH(8)) snapshot(.src_clk(source_clk),.src_rst(resets[0]),.src_stats(source_data),
        .dst_clk(clk),.dst_rst(resets[1]),.stats(captured),.valid(valid),.age_cycles(age));
    wire known=!resets[1] && valid;
    wire stale=known && age>STALE_CYCLES;
    // version1 / reserved14 / known / stale / coherent raw8. Raw retained stale.
    assign summary={8'd1,14'd0,known,stale,(known?captured:8'd0)};
endmodule
