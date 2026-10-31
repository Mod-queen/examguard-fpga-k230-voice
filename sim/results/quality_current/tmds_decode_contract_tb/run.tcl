open_vcd trace.vcd
set signals [get_objects -quiet {/tmds_decode_contract_tb/rst /tmds_decode_contract_tb/reset /tmds_decode_contract_tb/rst_n /tmds_decode_contract_tb/request /tmds_decode_contract_tb/accepted /tmds_decode_contract_tb/rejected /tmds_decode_contract_tb/event_valid /tmds_decode_contract_tb/result_valid /tmds_decode_contract_tb/result_ok /tmds_decode_contract_tb/protocol_fault /tmds_decode_contract_tb/video_fault /tmds_decode_contract_tb/frame_done /tmds_decode_contract_tb/init_done /tmds_decode_contract_tb/tx_qualified /tmds_decode_contract_tb/link_up /tmds_decode_contract_tb/errors /tmds_decode_contract_tb/state}]
if {[llength $signals]} {log_vcd $signals}
run all
close_vcd
quit
