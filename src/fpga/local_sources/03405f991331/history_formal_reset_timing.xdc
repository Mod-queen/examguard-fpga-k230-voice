# Only asynchronous first-stage/reset PRE pins; local release and data stay timed.
set_false_path -to [get_pins -of_objects [get_cells -hier -filter {NAME =~ history_lifecycle_inst/idle_meta_reg}] -filter {REF_PIN_NAME == D}]
set_false_path -to [get_pins -of_objects [get_cells -hier -filter {NAME =~ history_lifecycle_inst/idle_*_reg || NAME =~ history_lifecycle_inst/draining_reg}] -filter {REF_PIN_NAME == PRE || REF_PIN_NAME == CLR}]
# New bundled time snapshot is constrained by the same precise helper as other
# event/time bridges. Apply only this instance, never whole clock domains.
set_false_path -from [get_cells -hier -filter {NAME == hist_source_time_cdc/bridge/req_toggle_reg}] -to [get_pins -hier -filter {NAME == hist_source_time_cdc/bridge/req_meta_reg/D}]
set_false_path -from [get_cells -hier -filter {NAME == hist_source_time_cdc/bridge/ack_toggle_reg}] -to [get_pins -hier -filter {NAME == hist_source_time_cdc/bridge/ack_meta_reg/D}]
set_max_delay -datapath_only 13.468 -from [get_cells -hier -filter {NAME =~ hist_source_time_cdc/bridge/payload_hold_reg*}] -to [get_cells -hier -filter {NAME =~ hist_source_time_cdc/bridge/dst_data_reg*}]
