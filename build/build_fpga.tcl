# Independent quality candidate; board release is unchanged. This script never connects to hardware.
set root [file normalize [file join [file dirname [info script]] ..]]
set source [file join $root src fpga]
set out [file join $root build reproduced]
if {[llength $argv] > 0} {set out [file normalize [lindex $argv 0]]}
if {[file exists $out]} {error "Refuse overwrite existing build; choose a new output directory"}
file mkdir $out
set work [file join $out source]
file copy $source $work
set reports [file join $out reports]
file mkdir $reports
puts "REPRODUCE_VIVADO_VERSION=[version -short]"
puts "VALIDATED_TOOL_VERSION=2018.3 PART=xc7a200tfbg484-2"
open_project [file join $work ov5640_ddr3_hdmi_vga.xpr]
set_property ip_output_repo [file join $work ip_cache] [current_project]
foreach f [get_files -filter {FILE_TYPE == Verilog || FILE_TYPE == SystemVerilog || FILE_TYPE == XDC}] {
    if {![string match ${work}/* [file normalize $f]]} {error "Nonlocal source $f"}
}
update_compile_order -fileset sources_1
set display_stage {}
foreach f [get_files -compile_order sources -used_in synthesis] {
    if {[string match */display_output_pipeline.v $f]} {lappend display_stage $f}
}
if {[llength $display_stage]!=1} {error "HDMI pipeline missing from synthesis compile order"}
reset_run synth_1
set_property INCREMENTAL_CHECKPOINT {} [get_runs impl_1]
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
}
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Synthesis failed"}
open_run synth_1
report_utilization -hierarchical -hierarchical_depth 3 -file [file join $reports synthesis_hierarchy.rpt]
foreach pattern {{cdc_exam_status_inst/dst_sync_reg*} {cdc_frame_activity_inst/dst_sync_reg*} {evidence_busy_sync_reg*}} {
    set chain [get_cells -hier -filter "NAME =~ $pattern"]
    if {[llength $chain] < 2} {error "Missing synchronizer $pattern"}
    foreach c $chain {
        if {![get_property ASYNC_REG $c]} {error "Missing ASYNC_REG $c"}
    }
}
set ram [get_cells -hier -filter {NAME =~ evidence_log_queue_inst/* && (REF_NAME =~ RAMD* || REF_NAME =~ RAMS*)}]
if {[llength $ram] == 0} {error "Log queue did not infer distributed memory"}
set ram_file [open [file join $reports log_queue_memory.txt] w]
foreach c $ram {puts $ram_file "$c [get_property REF_NAME $c] [get_property PRIMITIVE_TYPE $c]"}
close $ram_file
opt_design
place_design
report_timing_summary -file [file join $reports placed_timing.rpt]
# Replicate only the measured high-fanout reset driver after placement.
# No extra reset cycle and no false timing exceptions are introduced.
set reset_driver [get_cells {status_reset_50m_ff_reg[1]}]
if {[llength $reset_driver] != 1} {error "Missing measured reset driver"}
set reset_nets [get_nets -of_objects [get_pins -of_objects $reset_driver -filter {REF_PIN_NAME == Q}]]
if {[llength $reset_nets] != 1} {error "Ambiguous reset net"}
phys_opt_design -force_replication_on_nets $reset_nets
phys_opt_design -directive Explore
write_checkpoint [file join $reports placed_optimized.dcp]
route_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
# Temporary EXTRA setup margin, added to the tool's jitter calculation.
# Original XDC has no user uncertainty. Restore zero added margin afterwards;
# all original clock definitions, computed jitter and hold checks remain.
set_clock_uncertainty -setup 0.250 [get_clocks]
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
report_timing_summary -file [file join $reports extra_margin_timing.rpt]
set_clock_uncertainty -setup 0.000 [get_clocks]
report_timing_summary -report_unconstrained -file [file join $reports timing.rpt]
report_timing -max_paths 15 -file [file join $reports critical_setup.rpt]
report_timing -delay_type min -max_paths 10 -file [file join $reports critical_hold.rpt]
report_cdc -details -file [file join $reports cdc.rpt]
report_cdc -details -all_checks_per_endpoint -file [file join $reports cdc_all.rpt]
report_cdc -details -all_checks_per_endpoint -file [file join $reports cdc_all_checks.rpt]
report_drc -file [file join $reports drc.rpt]
report_bus_skew -file [file join $reports bus_skew.rpt]
report_route_status -file [file join $reports route_status.rpt]
report_utilization -file [file join $reports utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 4 -file [file join $reports utilization_hier.rpt]
check_timing -verbose -file [file join $reports check_timing.rpt]
report_io -file [file join $reports io.rpt]
write_checkpoint [file join $reports routed.dcp]
foreach delay {max min} {
    set p [get_timing_paths -delay_type $delay -max_paths 1]
    if {[llength $p] != 1 || [get_property SLACK $p] < 0} {error "Timing failed; no bitstream"}
}
foreach {first second} {
    {cdc_exam_status_inst/dst_sync_reg[0]} {cdc_exam_status_inst/dst_sync_reg[1]}
    {cdc_frame_activity_inst/dst_sync_reg[0]} {cdc_frame_activity_inst/dst_sync_reg[1]}
    {evidence_busy_sync_reg[0]} {evidence_busy_sync_reg[1]}
} {
    foreach delay {max min} {
        set p [get_timing_paths -from [get_cells $first] -to [get_cells $second] -delay_type $delay -max_paths 1]
        if {[llength $p] != 1 || [get_property SLACK $p] < 0} {error "Synchronizer stage2 not timed: $first"}
    }
}
set bit [file join $out examguard_current_20261031.bit]
write_bitstream $bit
puts "CURRENT_SOURCE_BUILT=$bit"
exit
