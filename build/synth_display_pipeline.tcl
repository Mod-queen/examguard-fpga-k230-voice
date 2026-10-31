# Independent synthesis of the new module. No hardware access.
set root [file normalize [file join [file dirname [info script]] ..]]
if {[llength $argv]!=1} {error "Specify a new output directory"}
set out [file normalize [lindex $argv 0]]
if {[file exists $out]} {error "Refuse overwrite synthesis proof"}
file mkdir $out
read_verilog [file join $root src fpga local_sources quality display_output_pipeline.v]
synth_design -top display_output_pipeline -part xc7a200tfbg484-2
create_clock -name pixel -period 13.468 [get_ports clk]
report_utilization -file [file join $out utilization.rpt]
write_checkpoint [file join $out synthesized.dcp]
puts "DISPLAY_PIPELINE_SYNTHESIS_PASSED"
exit
