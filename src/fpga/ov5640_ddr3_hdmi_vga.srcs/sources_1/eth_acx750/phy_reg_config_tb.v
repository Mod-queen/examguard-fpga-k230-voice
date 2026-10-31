`timescale 1ns/1ps
////////////////////////////////////////////////////////////////////////////////////
// phy_reg_config_tb - self-checking test for the ExamGuard PHY bring-up.
//
// Checks:
//   1. The MDIO master writes BMCR (reg 0) with 0x1340 (auto-neg restart).
//   2. phy_init_done is released (link read-back OR settle fallback).
//
// A behavioural MDIO slave models an RTL8211F register bank: it captures writes
// and answers reads (BMSR = link + auto-neg complete, MII_STAT1000 = 1000M link).
////////////////////////////////////////////////////////////////////////////////////
module phy_reg_config_tb;

    reg         clk     = 1'b0;
    reg         rst_n   = 1'b0;
    wire        mdc;
    wire        mdio;
    wire [15:0] rddata;
    wire        phy_rst_n;
    wire        phy_init_done;
    wire        link_up;
    wire [1:0]  link_speed;

    // MDIO slave driver
    reg         mdio_oe = 1'b0;
    reg         mdio_o  = 1'b1;

    // Register bank
    reg [15:0]  reg_bank [0:31];

    // Frame reconstruction
    reg         framing = 1'b0;
    reg [6:0]   idx     = 7'd0;
    reg [6:0]   ones    = 7'd0;
    reg [1:0]   op_r;
    reg [4:0]   phyad_r;
    reg [4:0]   reg_addr_r;
    reg [15:0]  wr_sh;
    reg         wr_seen = 1'b0;

    wire [15:0] rd_mux;
    wire [15:0] wr_next = {wr_sh[14:0], mdio};

    always #10 clk = ~clk;  // 50 MHz

    pullup PUP (mdio);
    assign mdio = mdio_oe ? mdio_o : 1'bz;

    phy_reg_config #(
        .SYS_CLOCK  (50_000_000),
        .MDC_CLOCK  (1_000_000),
        .RST_HOLD   (20),
        .GO_CNT     (60),
        .CNT_MAX    (4000),
        .SETTLE_MAX (3000)
    ) dut (
        .clk          (clk          ),
        .rst_n        (rst_n        ),
        .phy_rst_n    (phy_rst_n    ),
        .rddata       (rddata       ),
        .phy_init_done(phy_init_done),
        .link_up      (link_up      ),
        .link_speed   (link_speed   ),
        .mdc          (mdc          ),
        .mdio         (mdio         )
    );

    integer i;
    initial begin
        for (i = 0; i < 32; i = i + 1) reg_bank[i] = 16'h0000;
        reg_bank[5'h01] = 16'h0024;   // BMSR: bit5 AN complete, bit2 link up
        reg_bank[5'h0A] = 16'h0800;   // MII_STAT1000: bit11 1000M link
    end

    assign rd_mux = (reg_addr_r == 5'h00) ? reg_bank[0]  :
                    (reg_addr_r == 5'h01) ? reg_bank[1]  :
                    (reg_addr_r == 5'h09) ? reg_bank[9]  :
                    (reg_addr_r == 5'h0A) ? reg_bank[10] :
                                            16'h0000;

    always @(posedge mdc or negedge rst_n) begin
        if (!rst_n) begin
            framing <= 1'b0; idx <= 7'd0; ones <= 7'd0;
            op_r <= 2'b00; phyad_r <= 5'd0; reg_addr_r <= 5'd0;
            wr_sh <= 16'd0; wr_seen <= 1'b0; mdio_oe <= 1'b0; mdio_o <= 1'b1;
        end else if (!framing) begin
            if (mdio) begin
                ones <= (ones < 7'd63) ? ones + 1'b1 : ones;
            end else if (ones >= 7'd32) begin
                framing <= 1'b1;   // this 0 is ST1; next edge is idx 1
                idx     <= 7'd1;
                ones    <= 7'd0;
            end else begin
                ones <= 7'd0;
            end
        end else begin
            case (idx)
                7'd2:  op_r[1] <= mdio;
                7'd3:  op_r[0] <= mdio;
                7'd4,7'd5,7'd6,7'd7,7'd8:      phyad_r    <= {phyad_r[3:0], mdio};
                7'd9,7'd10,7'd11,7'd12,7'd13:  reg_addr_r <= {reg_addr_r[3:0], mdio};
                7'd14: if (op_r == 2'b10) begin mdio_oe <= 1'b1; mdio_o <= 1'b0;  end
                7'd15: if (op_r == 2'b10) begin mdio_oe <= 1'b1; mdio_o <= rd_mux[15]; end
                7'd16: if (op_r == 2'b10) mdio_o <= rd_mux[14];
                7'd17: if (op_r == 2'b10) mdio_o <= rd_mux[13];
                7'd18: if (op_r == 2'b10) mdio_o <= rd_mux[12];
                7'd19: if (op_r == 2'b10) mdio_o <= rd_mux[11];
                7'd20: if (op_r == 2'b10) mdio_o <= rd_mux[10];
                7'd21: if (op_r == 2'b10) mdio_o <= rd_mux[9];
                7'd22: if (op_r == 2'b10) mdio_o <= rd_mux[8];
                7'd23: if (op_r == 2'b10) mdio_o <= rd_mux[7];
                7'd24: if (op_r == 2'b10) mdio_o <= rd_mux[6];
                7'd25: if (op_r == 2'b10) mdio_o <= rd_mux[5];
                7'd26: if (op_r == 2'b10) mdio_o <= rd_mux[4];
                7'd27: if (op_r == 2'b10) mdio_o <= rd_mux[3];
                7'd28: if (op_r == 2'b10) mdio_o <= rd_mux[2];
                7'd29: if (op_r == 2'b10) mdio_o <= rd_mux[1];
                7'd30: if (op_r == 2'b10) begin mdio_o <= rd_mux[0]; mdio_oe <= 1'b0; end
                default: ;
            endcase

            if (op_r == 2'b01 && idx >= 7'd16 && idx <= 7'd31)
                wr_sh <= wr_next;

            if (idx == 7'd31) begin
                framing <= 1'b0;
                idx     <= 7'd0;
                if (op_r == 2'b01) begin
                    reg_bank[reg_addr_r] <= wr_next;
                    if (reg_addr_r == 5'h00) wr_seen <= 1'b1;
                end
            end else begin
                idx <= idx + 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------- test flow
    integer wait_cnt;
    initial begin
        #200 rst_n = 1'b1;

        wait_cnt = 0;
        while (!phy_init_done && wait_cnt < 200000) begin
            @(posedge clk);
            wait_cnt = wait_cnt + 1;
        end

        if (!phy_init_done) begin
            $display("FAIL: phy_init_done never asserted (timeout)");
            $stop;
        end

        #5000;  // let the BMCR write settle into the register bank

        if (reg_bank[5'h00] !== 16'h1340) begin
            $display("FAIL: BMCR write mismatch, got 0x%04h (want 0x1340)", reg_bank[5'h00]);
            $stop;
        end

        $display("PASS: phy_init_done=1, BMCR=0x%04h, link_speed=%0d", reg_bank[5'h00], link_speed);
        $finish;
    end

endmodule
