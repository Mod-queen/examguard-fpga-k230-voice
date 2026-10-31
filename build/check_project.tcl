set root [file normalize [file join [file dirname [info script]] ..]]
set work [file join $root build reference_check_[clock seconds] source]
file mkdir [file dirname $work]
file copy [file join $root src fpga] $work
open_project [file join $work ov5640_ddr3_hdmi_vga.xpr]
set bad {}
foreach f [get_files -all] {
    if {![file exists $f]} {lappend bad $f}
}
update_compile_order -fileset sources_1
if {[llength $bad]} {error "Missing files: $bad"}
puts "SUBMISSION_PROJECT_REFERENCES_OK=[llength [get_files -all]]"
puts "TOP=[get_property TOP [get_filesets sources_1]] PART=[get_property PART [current_project]]"
close_project
exit
