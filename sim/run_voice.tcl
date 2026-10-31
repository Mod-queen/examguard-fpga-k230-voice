set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root sim results voice]
if {[file exists [file join $out project]]} {error "refuse overwrite voice simulation"}
file mkdir $out
cd $out
create_project voice_system_sim [file join $out project] -part xc7a200tfbg484-2
set lib [file join $root src rtl_support]
foreach name {i2c_byte_master i2c_register_master} {
    read_verilog -sv [file join $lib persistence ${name}.sv]
}
read_verilog [file join $lib event_identity cdc_event_transaction.v]
read_verilog [file join $lib health cdc_stats_snapshot.v]
foreach name {candidate_glyph candidate_overlay voice_info_confirm voice_exam_interaction voice_host_endpoint voice_status_record voice_notice_queue voice_audio_gate voice_interaction_bus voice_interaction_system wonderecho_wire_model voice_interaction_system_tb} {
    set candidates [glob -nocomplain [file join $root src fpga local_sources * ${name}.sv]]
    if {[llength $candidates]==1} {set f [lindex $candidates 0]} else {set f [file join $lib voice_interaction ${name}.sv]}
    read_verilog -sv $f
}
read_verilog [file join $root src fpga ov5640_ddr3_hdmi_vga.srcs sources_1 exam_fsm exam_fsm.v]
set_property top voice_interaction_system_tb [get_filesets sim_1]
set_property xsim.simulate.runtime 0ns [get_filesets sim_1]
launch_simulation
run all
close_sim
set simdir [file join $out project voice_system_sim.sim sim_1 behav xsim]
set f [open [file join $simdir simulate.log] r];set text [read $f];close $f
if {![regexp {PASS: voice_interaction_system scenarios=8} $text] || [regexp -nocase {fatal:|error:|test timeout} $text]} {error "Simulation failed"}
file copy [file join $simdir simulate.log] [file join $out simulate.log]
file copy [file join $simdir system_vi_trace.txt] [file join $out system_vi_trace.txt]
puts "SUBMISSION_VOICE_SIM_PASS_SCENARIOS_8"
close_project
exit
