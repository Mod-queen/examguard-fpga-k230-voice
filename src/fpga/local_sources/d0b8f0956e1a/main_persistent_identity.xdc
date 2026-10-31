set_property PACKAGE_PIN T18 [get_ports persist_scl]
set_property PACKAGE_PIN P16 [get_ports persist_sda]
set_property IOSTANDARD LVCMOS33 [get_ports {persist_scl persist_sda}]
# Asynchronous off-chip I2C input, first-stage synchronizers only.
set_false_path -from [get_ports persist_scl] -to [get_pins persistent_boot_inst/master/bytes/scl_meta_reg/D]
set_false_path -from [get_ports persist_sda] -to [get_pins persistent_boot_inst/master/bytes/sda_meta_reg/D]
# I2C electrical rise/fall-time remains a physical qualification; no fake delay.
