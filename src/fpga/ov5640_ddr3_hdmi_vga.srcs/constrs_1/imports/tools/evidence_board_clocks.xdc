# Independent evidence snapshot audit profile. No whole-domain exclusions.
# Camera table calls PCLK 42MHz; register-derived/fitted-board frequency and
# DVP board skew have not been measured. 100MHz is an explicit conservative
# INTERNAL timing envelope, NOT an external camera timing signoff assertion.
create_clock -name camera_pclk_audit -period 10.000 [get_ports camera_pclk]

# Actual RTL: MDC_CNT_M=50_000_000/2_000/4-1=6249; mdc toggles
# once each6250 control cycles, hence divide12500 (4kHz, not2kHz).
create_generated_clock -name phy_mdc -source [get_pins eth_phy_reg_config_inst/mdc_clk_reg/C] -divide_by 12500 [get_pins eth_phy_reg_config_inst/mdc_clk_reg/Q]

# RGMII forwarded clock is SAME_EDGE ODDR D1=1 D2=0. This names the
# clock at the pin, not an assumption that PHY TX delay is enabled.
create_generated_clock -name rgmii_txc -source [get_pins evidence_rgmii_inst/ODDR_rgmii_clk/C] -divide_by 1 [get_ports eth_gtx_clk]

# No made-up set_input/output_delay for DVP/RGMII/MDIO/SCCB/HDMI.
# External numbers require sensor/PHY datasheets, delay-mode confirmation and
# board/cable skew budgets. Missing interface coverage remains explicit.
