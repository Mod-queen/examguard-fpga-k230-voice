# Narrow constraints only; diagnostic clocks remain related/generated normally.
set_false_path -to [get_pins eth_qual_meta_reg/D]
set_max_delay -datapath_only 20.000 -from [get_cells -hier -filter {NAME =~ phy_health_inst/snapshot/bridge/payload_hold_reg*}] -to [get_cells -hier -filter {NAME =~ phy_health_inst/snapshot/bridge/dst_data_reg*}]
set_false_path -from [get_cells -hier -filter {NAME == phy_health_inst/snapshot/bridge/req_toggle_reg}] -to [get_pins phy_health_inst/snapshot/bridge/req_meta_reg/D]
set_false_path -from [get_cells -hier -filter {NAME == phy_health_inst/snapshot/bridge/ack_toggle_reg}] -to [get_pins phy_health_inst/snapshot/bridge/ack_meta_reg/D]
set_false_path -from [get_cells -hier -filter {NAME =~ phy_health_inst/barrier/domain*release_pipe_reg*}] -to [get_pins -of_objects [get_cells -hier -filter {NAME =~ phy_health_inst/barrier/domain*busy_meta_reg*}] -filter {REF_PIN_NAME == D}]
set_false_path -to [get_pins -of_objects [get_cells -hier -filter {NAME =~ phy_health_inst/barrier/* && ASYNC_REG == TRUE}] -filter {REF_PIN_NAME == PRE}]
