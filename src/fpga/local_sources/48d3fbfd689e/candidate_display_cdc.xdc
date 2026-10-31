# Only the named holding handshakes; second-stage and local logic remain timed.
set_false_path -to [get_pins candidate_to_pixel/bridge/req_meta_reg/D]
set_false_path -to [get_pins candidate_to_pixel/bridge/ack_meta_reg/D]
set_false_path -to [get_pins candidate_to_host/bridge/req_meta_reg/D]
set_false_path -to [get_pins candidate_to_host/bridge/ack_meta_reg/D]
set_max_delay -datapath_only 13.468 -from [get_cells -hier -filter {NAME =~ candidate_to_pixel/bridge/payload_hold_reg* && REF_NAME =~ FD*}] -to [get_cells -hier -filter {NAME =~ candidate_to_pixel/bridge/dst_data_reg* && REF_NAME =~ FD*}]
set_max_delay -datapath_only 20.000 -from [get_cells -hier -filter {NAME =~ candidate_to_host/bridge/payload_hold_reg* && REF_NAME =~ FD*}] -to [get_cells -hier -filter {NAME =~ candidate_to_host/bridge/dst_data_reg* && REF_NAME =~ FD*}]
