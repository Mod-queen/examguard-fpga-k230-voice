# Isolated local candidate only; no device connection or programming commands.
set root [file normalize [file join [file dirname [info script]] ..]]
set work [file join $root fpga examguard_scene_guard_rev03_work]
set out [file join $root verification_out scene_guard_rev03_20261030 build]
set bit [file join $root bit_ddr3_selftest history_evidence_top_scene_guard_rev03_2026-10-30.bit]
if {[file exists $bit] || [file exists [file join $out routed.dcp]]} {error "refuse overwrite completed candidate"}
file mkdir $out
open_project [file join $work ov5640_ddr3_hdmi_vga.xpr]
set_property ip_output_repo [file join $work ip_cache] [current_project]
if {[llength [get_files -quiet */camera_black_gate.v]]==0} {
    add_files -norecurse [file join $work local_sources camera_black_gate.v]
}
foreach f [get_files -filter {FILE_TYPE == Verilog || FILE_TYPE == SystemVerilog || FILE_TYPE == XDC}] {
    if {![string match ${work}/* [file normalize $f]]} {error "nonlocal source $f"}
}
update_compile_order -fileset sources_1
reset_run synth_1
set_property INCREMENTAL_CHECKPOINT {} [get_runs impl_1]
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "synthesis failed"}
open_run synth_1
foreach {name pin} {voice_scl C14 voice_sda C15} {
    if {[get_property PACKAGE_PIN [get_ports $name]] ne $pin} {error "voice pin changed $name"}
}
if {[llength [get_cells -hier -filter {NAME =~ cover98_inst/*}]]==0} {error "98 percent gate missing"}
opt_design
place_design
write_checkpoint [file join $out placed.dcp]
route_design -directive Explore
report_timing_summary -report_unconstrained -file [file join $out timing.rpt]
report_cdc -details -file [file join $out cdc.rpt]
report_drc -file [file join $out drc.rpt]
report_bus_skew -file [file join $out bus_skew.rpt]
report_route_status -file [file join $out route_status.rpt]
report_utilization -file [file join $out utilization.rpt]
report_io -file [file join $out io.rpt]
write_checkpoint [file join $out routed.dcp]
foreach delay {max min} {
    set p [get_timing_paths -delay_type $delay -max_paths 1]
    if {[llength $p]!=1 || [get_property SLACK $p]<0} {error "timing failed; no bit"}
}
set first [get_cells -hier -filter {NAME == cover98_sync_reg[0]}]
set second [get_cells -hier -filter {NAME == cover98_sync_reg[1]}]
if {[llength $first]!=1 || [llength $second]!=1} {error "cover synchronizer stages missing"}
set path [get_timing_paths -from $first -to $second -max_paths 1]
if {[llength $path]!=1 || [get_property SLACK $path]<0} {error "cover synchronizer second stage not timed"}
report_timing -from $first -to $second -file [file join $out cover_sync_timing.rpt]
write_bitstream $bit
puts "SCENE_GUARD_CANDIDATE_BUILT=$bit"
exit
