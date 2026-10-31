# =============================================================================
# CDC timing constraints for ProcessGuard
#
# Asynchronous clock domains in this design:
#   clk_out1_pll       50.000 MHz  control / UART / keys / buzzer
#   clk_out1_dvi_pll   74.250 MHz  pixel / display / workflow / evidence ring
#   clk_pll_i          100.000 MHz MIG UI clock (DDR3)
#   pclk_bufg_o        camera clock; evidence_board_clocks.xdc supplies a
#                     100MHz INTERNAL audit envelope, not external DVP signoff
#   phy_mdc           RTL-generated divide12500 control clock (4kHz)
#
# Every crossing below is an intentional CDC bridge:
#   * a two-flop synchronizer carrying a single toggle / level bit, or
#   * a multi-bit payload that is held stable while a toggle bit crosses.
#
# Constraints are stated per bridge. No global set_clock_groups is used, and no
# false path is applied between whole clock domains.
# =============================================================================

# -----------------------------------------------------------------------------
# Single-bit two-flop synchronizers: false path on the crossing register pair
# -----------------------------------------------------------------------------

# status_mailbox toggle (pixel -> 50 MHz)
set_false_path \
    -from [get_cells -hier -filter {NAME == status_mailbox_inst/src_toggle_reg}] \
    -to   [get_cells -hier -filter {NAME == status_mailbox_inst/dst_toggle_meta_reg}]

# Maintenance candidate retires the old ROI downlink. Its constant mailbox is
# optimized away, so there is no configuration-toggle crossing to constrain.

# evidence_dump byte handshake: request pixel -> 50 MHz, acknowledge 50 MHz -> pixel
set_false_path \
    -from [get_cells -hier -filter {NAME == evidence_dump_inst/byte_toggle_reg}] \
    -to   [get_cells -hier -filter {NAME == evidence_dump_inst/req_meta_reg}]
set_false_path \
    -from [get_cells -hier -filter {NAME == evidence_dump_inst/ack_toggle_reg}] \
    -to   [get_cells -hier -filter {NAME == evidence_dump_inst/ack_meta_reg}]

# pulse_cdc instances (key pulses and configuration-applied confirmation)
set_false_path \
    -from [get_cells -hier -filter {NAME == pulse_cdc_workflow_reset/src_toggle_reg}] \
    -to   [get_cells -hier -filter {NAME == pulse_cdc_workflow_reset/dst_meta_reg}]
set_false_path \
    -from [get_cells -hier -filter {NAME == pulse_cdc_manual_event/src_toggle_reg}] \
    -to   [get_cells -hier -filter {NAME == pulse_cdc_manual_event/dst_meta_reg}]
set_false_path \
    -from [get_cells -hier -filter {NAME == pulse_cdc_cfg_applied/src_toggle_reg}] \
    -to   [get_cells -hier -filter {NAME == pulse_cdc_cfg_applied/dst_meta_reg}]
# image evidence window-overrun event (pixel -> 50 MHz health monitor)
# Legacy BRAM overrun pulse is retired in this DDR-evidence snapshot.

# Buzzer mute level (50 MHz -> pixel) and evidence-busy level (pixel -> 50 MHz)
set_false_path \
    -to [get_pins {buzzer_mute_pixel_ff_reg[0]/D}]
set_false_path \
    -from [get_cells -hier -filter {NAME == evidence_dump_inst/busy_reg}] \
    -to   [get_cells -hier -filter {NAME == evidence_busy_sync_reg[0]}]

# Shared snapshot replaces the legacy address-clear flops. Each video_epoch_clear
# asynchronously asserts its OWN reset-synchronizer presets; only these PRE
# endpoints are excluded from recovery/removal. Q->D release-chain timing and
# ordinary client/FIFO logic remain timed. No clock-domain-wide exceptions.
set epoch_regs [get_cells -hier -filter {NAME =~ ddr3_ctrl_2port/fabric/video/*/release_ff_reg* && PRIMITIVE_GROUP == FLOP_LATCH}]
set epoch_presets [get_pins -of_objects $epoch_regs -filter {REF_PIN_NAME == PRE}]
set_false_path -to $epoch_presets

# Camera capture raw-fault assertion enters ONLY the local reset synchronizer.
# Its release Q -> capture CLR/PRE is a PCLK recovery/removal path, still timed.
set_false_path -to [get_pins -of_objects [get_cells -hier -filter {NAME =~ camera_capture_reset_inst/release_ff_reg* && PRIMITIVE_GROUP == FLOP_LATCH}] -filter {REF_PIN_NAME == PRE}]

# PHY common reset only targets local assertion synchronizer presets. Keep
# release Q -> divider/MDIO consumers' D and CLR/PRE timed in their own domains.
set_false_path -to [get_pins -of_objects [get_cells -hier -filter {NAME =~ eth_phy_reg_config_inst/control_release_reg* || NAME =~ eth_phy_reg_config_inst/mdio_release_reg*}] -filter {REF_PIN_NAME == PRE}]
# Sticky gigabit qualification returns to control domain through a 2FF level
# synchronizer; only first D crossing is excluded, meta->sync stays timed.
set_false_path -from [get_cells -hier -filter {NAME == eth_phy_reg_config_inst/link_rdy_reg}] -to [get_pins eth_phy_reg_config_inst/link_ready_meta_reg/D]

# CDC1 candidate: asynchronous level enters ONLY the first D of each chain.
# The second stage is clocked in the destination domain and MUST remain timed.
# Do not blanket-cut cells (which also excluded the second stage's D).
set_false_path -to [get_pins {ddr3_ready_pixel_ff_reg[0]/D}]
set_false_path -to [get_pins {ddr3_ready_50m_ff_reg[0]/D}]
set_false_path -to [get_pins {dvi_locked_pixel_ff_reg[0]/D}]
set_false_path -to [get_pins {dvi_locked_50m_ff_reg[0]/D}]

# New 98%-black episode level: only the first synchronizer input is asynchronous.
# Keep stage 1 -> stage 2 normally timed in the 50 MHz destination domain.
set_false_path -to [get_pins {cover98_sync_reg[0]/D}]

# -----------------------------------------------------------------------------
# Multi-bit payload buses held stable across a toggle handshake
#
# The destination only samples the payload one clock after synchronizing the
# toggle, so the bus has a full handshake to settle. A single destination clock
# period therefore bounds routing far more tightly than any data requirement.
# -----------------------------------------------------------------------------

# status_mailbox payload (pixel -> 50 MHz)
set_max_delay -datapath_only 20.000 \
    -from [get_cells -hier -filter {NAME =~ status_mailbox_inst/src_*_reg_reg* && PRIMITIVE_GROUP == FLOP_LATCH}] \
    -to   [get_cells -hier -filter {NAME =~ status_mailbox_inst/dst_*_reg* && PRIMITIVE_GROUP == FLOP_LATCH}]

# No old ROI payload crosses domains in this candidate (retired above).

# evidence_dump ASCII byte (pixel -> 50 MHz)
set_max_delay -datapath_only 20.000 \
    -from [get_cells -hier -filter {NAME =~ evidence_dump_inst/byte_hold_reg* && PRIMITIVE_GROUP == FLOP_LATCH}] \
    -to   [get_cells -hier -filter {NAME =~ evidence_dump_inst/tx_byte_reg* && PRIMITIVE_GROUP == FLOP_LATCH}]

# -----------------------------------------------------------------------------
# Image evidence byte channel (pixel -> 125 MHz)
# -----------------------------------------------------------------------------
# Single-bit request/acknowledge toggles through two-flop synchronizers

# The held payload byte is stable for the whole handshake; bound its routing
# instead of hiding it. eth_clk125 is the generated 125 MHz MMCM clock.
# Old PG byte channel removed in this evidence snapshot; new packet FIFO
# constraints are instance-scoped in evidence_integration_cdc.xdc.

# -----------------------------------------------------------------------------
# ExamGuard full-frame activity bridge (pixel -> 50 MHz)
# -----------------------------------------------------------------------------
set_false_path \
    -from [get_cells -hier -filter {NAME =~ cdc_frame_activity_inst/src_toggle_reg}] \
    -to   [get_cells -hier -filter {NAME == cdc_frame_activity_inst/dst_sync_reg[0]}]
set_max_delay -datapath_only 20.000 \
    -from [get_cells -hier -filter {NAME =~ cdc_frame_activity_inst/src_*_hold_reg*}] \
    -to   [get_cells -hier -filter {NAME =~ cdc_frame_activity_inst/dst_*_reg* && PRIMITIVE_GROUP == FLOP_LATCH}]

# -----------------------------------------------------------------------------
# ExamGuard exam-status bridge (50 MHz -> pixel)
# -----------------------------------------------------------------------------
set_false_path \
    -from [get_cells -hier -filter {NAME =~ cdc_exam_status_inst/src_toggle_reg}] \
    -to   [get_cells -hier -filter {NAME == cdc_exam_status_inst/dst_sync_reg[0]}]
set_max_delay -datapath_only 13.468 \
    -from [get_cells -hier -filter {NAME =~ cdc_exam_status_inst/src_hold_reg* && PRIMITIVE_GROUP == FLOP_LATCH}] \
    -to   [get_cells -hier -filter {NAME =~ cdc_exam_status_inst/dst_*_reg* && PRIMITIVE_GROUP == FLOP_LATCH}]

# -----------------------------------------------------------------------------
# PHY bring-up reset into the 125 MHz transmit domain
# -----------------------------------------------------------------------------
# eth_tx_reset_p is an asynchronous reset asserted from the 50 MHz PHY init /
# settle logic. Exclude the reset distribution path from setup/recovery analysis.
# PHY reset now enters reviewed barrier presets; do not cut its entire path
# into the Ethernet clock domain.
