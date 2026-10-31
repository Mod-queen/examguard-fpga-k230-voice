open_vcd trace.vcd
set signals [get_objects -quiet {/dvi_pipeline_contract_tb/rst /dvi_pipeline_contract_tb/reset /dvi_pipeline_contract_tb/rst_n /dvi_pipeline_contract_tb/request /dvi_pipeline_contract_tb/accepted /dvi_pipeline_contract_tb/rejected /dvi_pipeline_contract_tb/event_valid /dvi_pipeline_contract_tb/result_valid /dvi_pipeline_contract_tb/result_ok /dvi_pipeline_contract_tb/protocol_fault /dvi_pipeline_contract_tb/video_fault /dvi_pipeline_contract_tb/frame_done /dvi_pipeline_contract_tb/init_done /dvi_pipeline_contract_tb/tx_qualified /dvi_pipeline_contract_tb/link_up /dvi_pipeline_contract_tb/errors /dvi_pipeline_contract_tb/state}]
if {[llength $signals]} {log_vcd $signals}
run all
close_vcd
quit
