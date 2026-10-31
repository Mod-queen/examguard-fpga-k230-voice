# History-client evidence snapshot CDC constraints (Vivado 2018.3 XDC only).
# These replace the removed camera_evidence_transport paths. Not a global
# asynchronous clock group and not a route/board signoff.

# 50 MHz event transaction -> MIG UI clock (bundled held payload).
set_max_delay -datapath_only 10.000 -from [get_cells -hier -filter {NAME =~ hist_event_cdc/payload_hold_reg*}] -to [get_cells -hier -filter {NAME =~ hist_event_cdc/dst_data_reg*}]
set_false_path -from [get_cells -hier -filter {NAME == hist_event_cdc/req_toggle_reg}] -to [get_pins -of_objects [get_cells -hier -filter {NAME == hist_event_cdc/req_meta_reg}] -filter {REF_PIN_NAME == D}]
set_false_path -from [get_cells -hier -filter {NAME == hist_event_cdc/ack_toggle_reg}] -to [get_pins -of_objects [get_cells -hier -filter {NAME == hist_event_cdc/ack_meta_reg}] -filter {REF_PIN_NAME == D}]

# MIG UI clock -> sampling clock coherent time snapshot.
# Formal reset top uses hist_source_time_cdc from the same 50MHz event time.
# That path is bounded in history_formal_reset_timing.xdc; the unused internal
# client time snapshot is optimized away for EXTERNAL_CAP_TIME=1.

# Sampling -> MIG UI ordered command/pixel stream FIFO.
set hist_pix_w [get_pins -of_objects [get_cells -hier -filter {NAME =~ history_client_inst/bridge/fifo/rq1_wgray_reg*}] -filter {REF_PIN_NAME == D}]
set hist_pix_r [get_pins -of_objects [get_cells -hier -filter {NAME =~ history_client_inst/bridge/fifo/wq1_rgray_reg*}] -filter {REF_PIN_NAME == D}]
set_max_delay -datapath_only 10.000 -from [all_fanin -flat -startpoints_only -only_cells -to $hist_pix_w] -to $hist_pix_w
set_bus_skew 10.000 -from [all_fanin -flat -startpoints_only -only_cells -to $hist_pix_w] -to $hist_pix_w
set_max_delay -datapath_only 10.000 -from [all_fanin -flat -startpoints_only -only_cells -to $hist_pix_r] -to $hist_pix_r
set_bus_skew 10.000 -from [all_fanin -flat -startpoints_only -only_cells -to $hist_pix_r] -to $hist_pix_r

# MIG UI packet bytes -> Ethernet clock (pixel packet and HR record separately).
set hist_pkt_w [get_pins -of_objects [get_cells -hier -filter {NAME =~ history_pixel_cdc_inst/fifo/rq1_wgray_reg*}] -filter {REF_PIN_NAME == D}]
set hist_pkt_r [get_pins -of_objects [get_cells -hier -filter {NAME =~ history_pixel_cdc_inst/fifo/wq1_rgray_reg*}] -filter {REF_PIN_NAME == D}]
set_max_delay -datapath_only 8.000 -from [all_fanin -flat -startpoints_only -only_cells -to $hist_pkt_w] -to $hist_pkt_w
set_bus_skew 8.000 -from [all_fanin -flat -startpoints_only -only_cells -to $hist_pkt_w] -to $hist_pkt_w
set_max_delay -datapath_only 8.000 -from [all_fanin -flat -startpoints_only -only_cells -to $hist_pkt_r] -to $hist_pkt_r
set_bus_skew 8.000 -from [all_fanin -flat -startpoints_only -only_cells -to $hist_pkt_r] -to $hist_pkt_r
set hist_hr_w [get_pins -of_objects [get_cells -hier -filter {NAME =~ history_hr_cdc_inst/fifo/rq1_wgray_reg*}] -filter {REF_PIN_NAME == D}]
set hist_hr_r [get_pins -of_objects [get_cells -hier -filter {NAME =~ history_hr_cdc_inst/fifo/wq1_rgray_reg*}] -filter {REF_PIN_NAME == D}]
set_max_delay -datapath_only 8.000 -from [all_fanin -flat -startpoints_only -only_cells -to $hist_hr_w] -to $hist_hr_w
set_bus_skew 8.000 -from [all_fanin -flat -startpoints_only -only_cells -to $hist_hr_w] -to $hist_hr_w
set_max_delay -datapath_only 8.000 -from [all_fanin -flat -startpoints_only -only_cells -to $hist_hr_r] -to $hist_hr_r
set_bus_skew 8.000 -from [all_fanin -flat -startpoints_only -only_cells -to $hist_hr_r] -to $hist_hr_r

# 50 MHz single-cycle control pulses -> MIG UI identity.
set_false_path -to [get_pins -of_objects [get_cells -hier -filter {NAME == hist_ms_tick_cdc/dst_meta_reg}] -filter {REF_PIN_NAME == D}]
set_false_path -to [get_pins -of_objects [get_cells -hier -filter {NAME == hist_session_start_cdc/dst_meta_reg}] -filter {REF_PIN_NAME == D}]
set_false_path -to [get_pins -of_objects [get_cells -hier -filter {NAME == hist_session_end_cdc/dst_meta_reg}] -filter {REF_PIN_NAME == D}]

# Client epoch/barrier/identity cancellation synchronizers.
set_false_path -to [get_pins -of_objects [get_cells -hier -filter {NAME == history_client_inst/epoch/src_meta_reg || NAME == history_client_inst/epoch/dst_meta_reg}] -filter {REF_PIN_NAME == D}]
set_false_path -from [get_cells -hier -filter {NAME =~ history_client_inst/epoch/barrier/domain*release_pipe_reg*}] -to [get_pins -of_objects [get_cells -hier -filter {NAME =~ history_client_inst/epoch/barrier/domain*busy_meta_reg*}] -filter {REF_PIN_NAME == D}]
set_false_path -to [get_pins -of_objects [get_cells -hier -filter {NAME =~ history_client_inst/epoch/barrier/* && ASYNC_REG == TRUE}] -filter {REF_PIN_NAME == PRE}]
set_false_path -to [get_pins -of_objects [get_cells -hier -filter {NAME =~ history_client_inst/identity/startup_reg* || NAME == history_client_inst/identity/boot_pending_reg}] -filter {REF_PIN_NAME == PRE}]

# Read-only health statistics snapshots (unchanged telemetry instances).
set_max_delay -datapath_only 20.000 -from [get_cells -hier -filter {NAME =~ evidence_health_inst/ui_snapshot/bridge/payload_hold_reg*}] -to [get_cells -hier -filter {NAME =~ evidence_health_inst/ui_snapshot/bridge/dst_data_reg*}]
set_false_path -from [get_cells -hier -filter {NAME == evidence_health_inst/ui_snapshot/bridge/req_toggle_reg}] -to [get_pins evidence_health_inst/ui_snapshot/bridge/req_meta_reg/D]
set_false_path -from [get_cells -hier -filter {NAME == evidence_health_inst/ui_snapshot/bridge/ack_toggle_reg}] -to [get_pins evidence_health_inst/ui_snapshot/bridge/ack_meta_reg/D]
set_max_delay -datapath_only 20.000 -from [get_cells -hier -filter {NAME =~ evidence_health_inst/eth_snapshot/bridge/payload_hold_reg*}] -to [get_cells -hier -filter {NAME =~ evidence_health_inst/eth_snapshot/bridge/dst_data_reg*}]
set_false_path -from [get_cells -hier -filter {NAME == evidence_health_inst/eth_snapshot/bridge/req_toggle_reg}] -to [get_pins evidence_health_inst/eth_snapshot/bridge/req_meta_reg/D]
set_false_path -from [get_cells -hier -filter {NAME == evidence_health_inst/eth_snapshot/bridge/ack_toggle_reg}] -to [get_pins evidence_health_inst/eth_snapshot/bridge/ack_meta_reg/D]


# Local synchronous reads of the asynchronous FIFO LUTRAMs and the unchanged
# top barrier/identity synchronizers.
set hist_ui_clock [get_clocks -of_objects [get_pins {history_client_inst/bridge/fifo/rq1_wgray_reg[0]/C}]]
set hist_eth_clock [get_clocks -of_objects [get_pins {history_pixel_cdc_inst/fifo/rq1_wgray_reg[0]/C}]]
set_max_delay -datapath_only 10.000 -from [get_pins -of_objects [get_cells -hier -filter {NAME =~ history_client_inst/bridge/fifo/mem_reg* && REF_NAME =~ RAMD*}] -filter {REF_PIN_NAME == CLK}] -to $hist_ui_clock
set_max_delay -datapath_only 8.000 -from [get_pins -of_objects [get_cells -hier -filter {NAME =~ history_pixel_cdc_inst/fifo/mem_reg* && REF_NAME =~ RAMD*}] -filter {REF_PIN_NAME == CLK}] -to $hist_eth_clock
set_max_delay -datapath_only 8.000 -from [get_pins -of_objects [get_cells -hier -filter {NAME =~ history_hr_cdc_inst/fifo/mem_reg* && REF_NAME =~ RAMD*}] -filter {REF_PIN_NAME == CLK}] -to $hist_eth_clock
set_false_path -from [get_cells -hier -filter {NAME =~ evidence_reset_barrier_inst/domain*release_pipe_reg*}] -to [get_pins -of_objects [get_cells -hier -filter {NAME =~ evidence_reset_barrier_inst/domain*busy_meta_reg*}] -filter {REF_PIN_NAME == D}]
set_false_path -to [get_pins -of_objects [get_cells -hier -filter {NAME =~ evidence_reset_barrier_inst/* && ASYNC_REG == TRUE}] -filter {REF_PIN_NAME == PRE}]
set_false_path -to [get_pins -of_objects [get_cells -hier -filter {NAME =~ evidence_identity_inst/startup_reg* || NAME == evidence_identity_inst/boot_pending_reg}] -filter {REF_PIN_NAME == PRE}]
set_false_path -from [get_cells -hier -filter {NAME == evidence_health_inst/cap_snapshot/bridge/req_toggle_reg}] -to [get_pins evidence_health_inst/cap_snapshot/bridge/req_meta_reg/D]
set_false_path -from [get_cells -hier -filter {NAME == evidence_health_inst/cap_snapshot/bridge/ack_toggle_reg}] -to [get_pins evidence_health_inst/cap_snapshot/bridge/ack_meta_reg/D]
set_false_path -to [get_pins -of_objects [get_cells -hier -filter {NAME =~ hist_eth_meta_reg || NAME =~ hist_eth_sync_reg}] -filter {REF_PIN_NAME == CLR || REF_PIN_NAME == PRE}]
set_false_path -to [get_pins -of_objects [get_cells -hier -filter {NAME =~ video_fabric_rst_sync_reg*}] -filter {REF_PIN_NAME == PRE || REF_PIN_NAME == CLR}]
