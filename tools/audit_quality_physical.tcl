# Read-only post-route audit: never opens hardware, never edits constraints.
if {[llength $argv] != 2} {error "Usage: checkpoint output_directory"}
set checkpoint [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
if {[file exists $out]} {error "Refuse overwrite audit output"}
file mkdir $out
open_checkpoint $checkpoint
set clocks_file [open [file join $out clock_periods.tsv] w]
puts $clocks_file "clock\tperiod_ns"
foreach {name period} {clk_out1_pll 20.000 clk_out1_dvi_pll 13.468 clk_pll_i 10.000 eth_clk125_unbuf 8.000 camera_pclk_audit 10.000 phy_mdc 250000.000} {
 set c [get_clocks $name]
 # Generated slow clocks carry Vivado floating-point rounding (12ps/250us).
 set tolerance [expr {max(0.001,abs($period)*0.000001)}]
 if {[llength $c]!=1 || abs([get_property PERIOD $c]-$period)>$tolerance} {error "Clock definition changed: $name"}
 puts $clocks_file "$name\t[get_property PERIOD $c]"
}
close $clocks_file
set h [open [file join $out synchronizer_paths.tsv] w]
puts $h "first\tsecond\tdelay\tslack_ns\tpath_requirement_ns"
set pairs {
 {cdc_exam_status_inst/dst_sync_reg[0]} {cdc_exam_status_inst/dst_sync_reg[1]}
 {cdc_frame_activity_inst/dst_sync_reg[0]} {cdc_frame_activity_inst/dst_sync_reg[1]}
 {evidence_busy_sync_reg[0]} {evidence_busy_sync_reg[1]}
 {ddr3_ready_pixel_ff_reg[0]} {ddr3_ready_pixel_ff_reg[1]}
 {ddr3_ready_50m_ff_reg[0]} {ddr3_ready_50m_ff_reg[1]}
 {dvi_locked_pixel_ff_reg[0]} {dvi_locked_pixel_ff_reg[1]}
 {dvi_locked_50m_ff_reg[0]} {dvi_locked_50m_ff_reg[1]}
 {cover98_sync_reg[0]} {cover98_sync_reg[1]}
 {ai_link_rx_inst/rx_sync_reg[0]} {ai_link_rx_inst/rx_sync_reg[1]}
 {uart_rx_inst/rx_meta_reg} {uart_rx_inst/rx_sync_reg}
}
for {set i 0} {$i<8} {incr i} {
 lappend pairs [format {board_status_inst/sw_meta_reg[%d]} $i] [format {board_status_inst/sw_sync_reg[%d]} $i]
}
for {set i 0} {$i<4} {incr i} {
 lappend pairs [format {user_control_inst/g_key[%d].key_debounce_inst/key_meta_reg} $i] [format {user_control_inst/g_key[%d].key_debounce_inst/key_sync_reg} $i]
}
foreach {first second} $pairs {
 set a [get_cells $first];set b [get_cells $second]
 if {[llength $a]!=1 || [llength $b]!=1} {error "Missing synchronizer $first -> $second"}
 foreach c [concat $a $b] {if {![get_property ASYNC_REG $c]} {error "ASYNC_REG missing on $c"}}
 foreach delay {max min} {
  set path [get_timing_paths -from $a -to $b -delay_type $delay -max_paths 1]
  if {[llength $path]!=1 || [get_property SLACK $path]<0} {error "Untimed or failed second stage $first $delay"}
  puts $h "$first\t$second\t$delay\t[get_property SLACK $path]\t[get_property REQUIREMENT $path]"
 }
}
close $h
set ready [get_cells ddr3_ready_source_reg]
if {[llength $ready]!=1} {error "Source-domain readiness register missing"}
report_timing -to $ready -max_paths 10 -file [file join $out ready_source.rpt]
set h [open [file join $out reset_distribution.tsv] w]
puts $h "driver\tdirect_loads\ttransitive_endpoints\tmax_slack_ns\tmin_slack_ns"
foreach c [get_cells -hier -filter {NAME =~ *status_reset_50m_ff_reg* && PRIMITIVE_GROUP == FLOP_LATCH}] {
 set q [get_pins -of_objects $c -filter {REF_PIN_NAME == Q}]
 set loads [all_fanout -flat -endpoints_only -from $q]
 set direct [get_pins -leaf -of_objects [get_nets -of_objects $q] -filter {DIRECTION == IN}]
 set row [list $c [llength $direct] [llength $loads]]
 foreach delay {max min} {
  set p [get_timing_paths -from $q -delay_type $delay -max_paths 1]
  if {[llength $p]} {lappend row [get_property SLACK $p]} else {lappend row no_timed_path}
 }
 puts $h [join $row "\t"]
}
close $h
set h [open [file join $out fifo_storage_paths.tsv] w]
puts $h "instance\tslack_ns\trequirement_ns\tstartpoint\tendpoint"
foreach instance {history_hr_cdc_inst history_pixel_cdc_inst} {
 set memory [get_cells -hier -filter "NAME =~ $instance/fifo/mem* && (REF_NAME =~ RAMD* || REF_NAME =~ RAMS*)"]
 set receivers [get_cells -hier -filter "NAME =~ $instance/dst_*reg* && PRIMITIVE_GROUP == FLOP_LATCH"]
 if {![llength $memory] || ![llength $receivers]} {error "Missing FIFO endpoints $instance"}
 set p [get_timing_paths -from $memory -to $receivers -delay_type max -max_paths 1]
 if {[llength $p]!=1 || [get_property SLACK $p]<0} {error "FIFO storage path not bounded $instance"}
 puts $h "$instance\t[get_property SLACK $p]\t[get_property REQUIREMENT $p]\t[get_property STARTPOINT_PIN $p]\t[get_property ENDPOINT_PIN $p]"
 report_timing -from $memory -to $receivers -max_paths 5 -file [file join $out ${instance}_storage.rpt]
}
close $h
set h [open [file join $out asynchronous_input_sinks.tsv] w]
puts $h "port\tendpoint\tASYNC_REG"
foreach port [get_ports {ai_uart_rx uart_rxd key[*] switches[*]}] {
 foreach pin [all_fanout -flat -endpoints_only -from $port] {
  set cell [get_cells -of_objects $pin]
  puts $h "$port\t$pin\t[get_property ASYNC_REG $cell]"
 }
}
close $h
report_high_fanout_nets -timing -load_types -max_nets 20 -file [file join $out high_fanout.rpt]
puts "QUALITY_PHYSICAL_AUDIT_PASSED"
close_design
exit
