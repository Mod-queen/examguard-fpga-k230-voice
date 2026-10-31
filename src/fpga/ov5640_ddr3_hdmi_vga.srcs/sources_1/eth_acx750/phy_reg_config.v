`timescale 1ns/1ns
////////////////////////////////////////////////////////////////////////////////////
// phy_reg_config - ACX750 RTL8211F bring-up (ExamGuard)
//
// Root cause this module addresses:
//   The previous version forced the PHY speed with auto-negotiation DISABLED
//   and only "wrote two registers" without ever reading the PHY back.
//   RTL8211F requires auto-negotiation for 1000BASE-T, so the link could settle
//   at 100 Mbps while gmii_to_rgmii keeps driving a fixed 125 MHz DDR RGMII
//   clock -> intermittent / corrupt UDP.
//
// New behaviour:
//   1. Release PHY reset, then restart auto-negotiation with the PHY default
//      advertisement (BMCR = 0x1340: AN enable + AN restart + full duplex +
//      1000M speed bits), exactly the rates the vendor demo relies on.
//   2. Read ID, BMSR twice, D08 delay controls and A43 actual speed/link.
//      Every page selection is read back; every sweep restores/checks page0.
//      GBSR partner capability is NOT used to infer the current link speed.
//   3. phy_init_done preserves legacy settle fallback; tx_qualified is a
//      separate live, synchronized qualification, never bypassed by timeout.
//      The evidence top uses qualification for local packet/MAC admission only,
//      independently of shared video AXI reset.
//   Exclusive MDIO ownership: page0 is the baseline, not a shared-master API.
//   Delay registers are read only; this module does not change board straps.
//
// link_up / link_speed are outputs; instantiations that leave them open remain
// valid (named connections).
////////////////////////////////////////////////////////////////////////////////////
module phy_reg_config #(
    // Kept for source compatibility with older instantiations. Advertisement is
    // now driven by the PHY default; `speed` no longer forces the link rate.
    parameter [1:0] speed      = 2'b10,
    parameter       SYS_CLOCK  = 50_000_000,
    parameter       MDC_CLOCK  = 2_000,
    parameter       MAX_CNT    = 2,
    parameter integer RST_HOLD  = 500_000,        // phy_rst_n release @50 MHz
    parameter integer GO_CNT    = 1_499_999,      // start MDIO @50 MHz
    parameter integer CNT_MAX   = 3_000_000,      // counter wrap @50 MHz
    parameter integer SETTLE_MAX= 50_000_000      // fallback release ~1 s @50 MHz
) (
    input             clk,
    input             rst_n,
    output            phy_rst_n,
    output     [15:0] rddata,
    output            phy_init_done,
    output reg        tx_qualified, // registered control-domain live level
    output reg        status_valid, // all following diagnostics: MDC domain
    output reg [31:0] phy_id,
    output reg [15:0] tx_delay_raw,
    output reg [15:0] rx_delay_raw,
    output reg [15:0] physr_raw,
    output reg [15:0] speed_raw,
    output reg        full_duplex,
    output reg        link_up,
    output reg [1:0]  link_speed,
    output            mdc,
    inout             mdio
);

    localparam MDC_CNT_M = SYS_CLOCK / MDC_CLOCK / 4 - 1;

    // Independent evidence snapshot lifecycle: common reset asserts without
    // either clock, releases only on three clean control edges. MDC's actual
    // divider/waveform stays unchanged (MDC_CLOCK2000 -> 4kHz at50MHz).
    (* ASYNC_REG="TRUE" *) reg [2:0] control_release;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) control_release <= 3'b111;
        else control_release <= {control_release[1:0],1'b0};
    wire control_rst = control_release[2];

    // ---------------------------------------------------------------- MDC clock
    // Full-period phase counter preserves every MDC edge, including reset.
    // The clock output is decoded from phase, without Q->D clock feedback.
    localparam integer MDC_PERIOD_CYCLES = 2 * (MDC_CNT_M + 1);
    localparam integer MDC_PHASE_WIDTH = (MDC_PERIOD_CYCLES < 2) ? 1 : $clog2(MDC_PERIOD_CYCLES);
    reg [MDC_PHASE_WIDTH-1:0] div_cnt;
    always @(posedge clk)
        if (control_rst)
            div_cnt <= 0;
        else if (div_cnt == MDC_PERIOD_CYCLES-1)
            div_cnt <= 0;
        else
            div_cnt <= div_cnt + 1'b1;

    reg mdc_clk;
    always @(posedge clk)
        if (control_rst)
            mdc_clk <= 1'b0;
        else
            mdc_clk <= (div_cnt >= MDC_CNT_M) && (div_cnt < MDC_PERIOD_CYCLES-1);

    assign mdc = mdc_clk;

    // ------------------------------------------------- PHY reset / settle timing
    // phy_rst_n released after RST_HOLD; MDIO starts after GO_CNT @50 MHz.
    reg [31:0] cnt;
    reg phy_reset_released;
    reg management_go;
    always @(posedge clk or posedge control_rst)
        if (control_rst) begin
            cnt <= 'd0;
            phy_reset_released <= 1'b0;
            management_go <= 1'b0;
        end else begin
            if (cnt < CNT_MAX) cnt <= cnt + 1'b1;
            // Register decoded thresholds so the slow-domain asynchronous
            // reset cannot glitch when several counter bits change together.
            phy_reset_released <= (cnt > RST_HOLD);
            management_go <= (cnt > GO_CNT) && phy_reset_released;
        end
    assign phy_rst_n = phy_reset_released;

    // Both MDIO engines share assertion and THREE negedge-MDC release stages.
    // A stopped MDC cannot release either engine. First work is on the edge
    // after mdio_rst drops; never sample a raw Go decode as FSM synchronous R.
    (* ASYNC_REG="TRUE" *) reg [2:0] mdio_release;
    always @(negedge mdc or negedge management_go)
        if (!management_go) mdio_release <= 3'b111;
        else mdio_release <= {mdio_release[1:0],1'b0};
    wire mdio_rst = mdio_release[2];

    // Fallback settle timer (independent of MDIO read success).
    reg [31:0] settle;
    always @(posedge clk)
        if (control_rst)
            settle <= 'd0;
        else if (settle < SETTLE_MAX)
            settle <= settle + 1'b1;

    wire settle_done = (settle >= SETTLE_MAX);

    // ------------------------------------------------------------------ MDIO FSM
    wire        done;
    wire        mdio_read_valid;
    reg         start;
    reg         if_read_r;
    reg  [4:0]  phy_addr_r;
    reg  [4:0]  reg_addr_r;
    reg  [15:0] wrdata_r;

    mdio_bit_shift mdio_bit_shift (
        .mdc      (mdc        ),
        .rst_n    (~mdio_rst  ),
        .if_read  (if_read_r  ),
        .start    (start      ),
        .phy_addr (phy_addr_r ),
        .reg_addr (reg_addr_r ),
        .wrdata   (wrdata_r   ),
        .rddata   (rddata     ),
        .read_valid(mdio_read_valid),
        .done     (done       ),
        .mdio     (mdio       )
    );

    // One command per step, separated into issue and completion cycles.
    // 0/1 page0, 2/3 ID, 4 BMCR-once, 5/6 BMSR, 7/8 D08,
    // 9/10 delay, 11/12 A43, 13/14 status, 15/16 restore page0.
    reg [4:0] step;
    reg waiting, configured, sweep_ok;
    reg [15:0] id1_hold,id2_hold,bmsr_hold,tx_hold,rx_hold,physr_hold,speed_hold;
    reg link_rdy;

    (* ASYNC_REG="TRUE" *) reg link_ready_meta,link_ready_sync;
    reg init_qualified_seen;
    always @(posedge clk) begin
        if (control_rst) begin link_ready_meta<=1'b0;link_ready_sync<=1'b0;init_qualified_seen<=0;end
        else begin
            link_ready_meta<=link_rdy;link_ready_sync<=link_ready_meta;
            if(link_ready_sync) init_qualified_seen<=1;
        end
    end
    assign phy_init_done = !control_rst && (init_qualified_seen | settle_done);
    // CDC2: no combinational gate before the top's 125MHz synchronizer.
    // Reset assertion still invalidates qualification without waiting for clk;
    // requalification requires a clean control edge after link synchronization.
    always @(posedge clk or posedge control_rst)
        if (control_rst) tx_qualified <= 1'b0;
        else tx_qualified <= link_ready_sync;

    wire id_matches = {id1_hold,id2_hold} == 32'h001cc916;
    wire speed_consistent = (physr_hold[5:4] != 2'b11) &&
                            ((speed_hold & 16'h0630) == {10'd0,physr_hold[5:4],4'd0});
    wire live_link = bmsr_hold[2] && bmsr_hold[5] && physr_hold[2];

    always @(negedge mdc or posedge mdio_rst) begin
        if (mdio_rst) begin
            step         <= 0;
            waiting      <= 0;
            configured   <= 0;
            sweep_ok     <= 0;
            id1_hold<=0;id2_hold<=0;bmsr_hold<=0;tx_hold<=0;rx_hold<=0;physr_hold<=0;speed_hold<=0;
            phy_id<=0;tx_delay_raw<=0;rx_delay_raw<=0;physr_raw<=0;speed_raw<=0;
            status_valid<=0;full_duplex<=0;
            start        <= 1'b0;
            if_read_r    <= 1'b0;
            phy_addr_r   <= 5'd0;
            reg_addr_r   <= 5'd0;
            wrdata_r     <= 16'd0;
            link_rdy     <= 1'b0;
            link_up      <= 1'b0;
            link_speed   <= 2'd0;
        end else begin
            start <= 0;
            if (!waiting) begin
                start<=1;waiting<=1;if_read_r<=1;wrdata_r<=0;
                case(step)
                    0: begin reg_addr_r<=31;if_read_r<=0;wrdata_r<=0;sweep_ok<=1;end
                    1,8,12,16: reg_addr_r<=31;
                    2: reg_addr_r<=2;
                    3: reg_addr_r<=3;
                    4: begin
                        reg_addr_r<=0;wrdata_r<=16'h1340;if_read_r<=0;
                        if(configured) begin start<=0;waiting<=0;step<=5;end
                    end
                    5,6: reg_addr_r<=1;
                    7: begin reg_addr_r<=31;if_read_r<=0;wrdata_r<=16'h0d08;end
                    9: reg_addr_r<=5'h11;
                    10: reg_addr_r<=5'h15;
                    11: begin reg_addr_r<=31;if_read_r<=0;wrdata_r<=16'h0a43;end
                    13: reg_addr_r<=5'h1a;
                    14: reg_addr_r<=5'h12;
                    15: begin reg_addr_r<=31;if_read_r<=0;wrdata_r<=0;end
                    default: begin start<=0;waiting<=0;step<=0;link_rdy<=0;status_valid<=0;end
                endcase
            end else if(done) begin
                waiting<=0;step<=step+1'b1;
                if (if_read_r && !mdio_read_valid) begin
                    sweep_ok<=0;status_valid<=0;link_rdy<=0;link_up<=0;link_speed<=0;full_duplex<=0;
                    step<=15; // Always restore page0 before retry, even on bad TA.
                end
                case(step)
                    1,8,12: begin
                        if(!mdio_read_valid || rddata!=(step==1?16'h0000:step==8?16'h0d08:16'h0a43)) begin
                            sweep_ok<=0;status_valid<=0;link_rdy<=0;link_up<=0;link_speed<=0;full_duplex<=0;step<=15;
                        end
                    end
                    2: id1_hold<=rddata;
                    3: begin
                        id2_hold<=rddata;
                        if(!mdio_read_valid || {id1_hold,rddata}!=32'h001cc916) begin
                            sweep_ok<=0;status_valid<=0;link_rdy<=0;link_up<=0;link_speed<=0;full_duplex<=0;step<=15;
                        end
                    end
                    4: configured<=1;
                    6: begin
                        bmsr_hold<=rddata;
                        if(!mdio_read_valid || (rddata & 16'h0024)!=16'h0024) begin link_rdy<=0;link_up<=0;end
                    end
                    9: begin tx_hold<=rddata;if(!mdio_read_valid || !rddata[8]) link_rdy<=0;end
                    10: rx_hold<=rddata;
                    13: begin
                        physr_hold<=rddata;
                        if(!mdio_read_valid || !rddata[2] || !rddata[3] || rddata[5:4]!=2'b10) link_rdy<=0;
                    end
                    14: begin speed_hold<=rddata;if(!mdio_read_valid || (rddata & 16'h0630)!=16'h0020) link_rdy<=0;end
                    16: begin
                        step<=0;
                        // Publish one sweep only after final page0 restoration.
                        phy_id<={id1_hold,id2_hold};tx_delay_raw<=tx_hold;rx_delay_raw<=rx_hold;
                        physr_raw<=physr_hold;speed_raw<=speed_hold;
                        status_valid<=sweep_ok && mdio_read_valid && rddata==0 && id_matches;
                        link_up<=sweep_ok && mdio_read_valid && rddata==0 && id_matches && live_link && speed_consistent;
                        link_speed<=(sweep_ok && mdio_read_valid && rddata==0 && id_matches && live_link && speed_consistent)?physr_hold[5:4]:2'd0;
                        full_duplex<=sweep_ok && mdio_read_valid && rddata==0 && id_matches && live_link && physr_hold[3];
                        link_rdy<=sweep_ok && mdio_read_valid && rddata==0 && id_matches && live_link && speed_consistent &&
                                  physr_hold[3] && physr_hold[5:4]==2'b10 && tx_hold[8];
                    end
                endcase
            end
        end
    end

    // synthesis translate_off
    initial begin
        if (MDC_CNT_M < 0 || MDC_CNT_M >= 1048576 || GO_CNT <= RST_HOLD || CNT_MAX <= GO_CNT)
            $fatal(1,"FAIL: PHY divider/reset timing parameters");
    end
    // synthesis translate_on

endmodule
