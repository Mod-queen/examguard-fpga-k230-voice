# OOC-only datapath constraints for the single async byte FIFO crossing.
# This is NOT a global asynchronous clock group and NOT a route/board signoff.
set_max_delay -datapath_only -from [get_clocks src] -to [get_clocks dst] 10.000
set_max_delay -datapath_only -from [get_clocks dst] -to [get_clocks src] 10.000
