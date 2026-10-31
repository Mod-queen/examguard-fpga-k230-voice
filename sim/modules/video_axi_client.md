# video_axi_client

当前工程实例化：是。关联7个自检用例。

| 用例 | 仿真器 | 当前结果 | 运行日志 | 结果记录 |
| --- | --- | --- | --- | --- |
| event_cdc_evidence_tb | xsim | 通过 | [日志](../../sim/results/quality_current/event_cdc_evidence_tb/run.log) | [记录](../../sim/results/quality_current/event_cdc_evidence_tb/result.json) |
| evidence_wrapper_reset_tb | xsim | 通过 | [日志](../../sim/results/quality_current/evidence_wrapper_reset_tb/run.log) | [记录](../../sim/results/quality_current/evidence_wrapper_reset_tb/result.json) |
| shared_evidence_axi_tb | xsim | 通过 | [日志](../../sim/results/quality_current/shared_evidence_axi_tb/run.log) | [记录](../../sim/results/quality_current/shared_evidence_axi_tb/result.json) |
| video_axi_client_edges_tb | icarus | 通过 | [日志](../../sim/results/quality_current/video_axi_client_edges_tb/run.log) | [记录](../../sim/results/quality_current/video_axi_client_edges_tb/result.json) |
| video_axi_client_tb | icarus | 通过 | [日志](../../sim/results/quality_current/video_axi_client_tb/run.log) | [记录](../../sim/results/quality_current/video_axi_client_tb/result.json) |
| video_memory_clear_cross_tb | xsim | 通过 | [日志](../../sim/results/quality_current/video_memory_clear_cross_tb/run.log) | [记录](../../sim/results/quality_current/video_memory_clear_cross_tb/result.json) |
| video_memory_fabric_tb | xsim | 通过 | [日志](../../sim/results/quality_current/video_memory_fabric_tb/run.log) | [记录](../../sim/results/quality_current/video_memory_fabric_tb/result.json) |

单独重跑本模块关联用例（工程根目录）：

```powershell
python sim/run_module_tests.py --only event_cdc_evidence_tb evidence_wrapper_reset_tb shared_evidence_axi_tb video_axi_client_edges_tb video_axi_client_tb video_memory_clear_cross_tb video_memory_fabric_tb --vivado-bin "$env:EXAMGUARD_VIVADO_BIN" --iverilog-bin "$env:EXAMGUARD_IVERILOG_BIN"
```

先按[复原说明](../../build/reproduction.md)配置工具。每次生成新的结果目录。

## event_cdc_evidence_tb

用例源码：[event_cdc_evidence_tb.sv](../../sim/sources/ddr3_test/event_cdc_evidence_tb.sv), [axi_frame_slave_model.sv](../../sim/sources/ddr3_test/axi_frame_slave_model.sv)

历史VCD数据导出图（并非Vivado截图）：

![event_cdc_evidence_tb](../../sim/images/event_cdc_evidence_tb.png)

## evidence_wrapper_reset_tb

用例源码：[evidence_wrapper_reset_tb.sv](../../sim/test_repairs/evidence_wrapper_reset_tb/evidence_wrapper_reset_tb.sv), [axi_frame_slave_model.sv](../../sim/sources/ddr3_test/axi_frame_slave_model.sv), [mig_axi_reset_contract_model.sv](../../sim/test_repairs/evidence_wrapper_reset_tb/mig_axi_reset_contract_model.sv)

历史VCD数据导出图（并非Vivado截图）：

![evidence_wrapper_reset_tb](../../sim/images/evidence_wrapper_reset_tb.png)

## shared_evidence_axi_tb

用例源码：[shared_evidence_axi_tb.sv](../../sim/sources/ddr3_test/shared_evidence_axi_tb.sv), [axi_frame_slave_model.sv](../../sim/sources/ddr3_test/axi_frame_slave_model.sv), [video_fifo_path_source.sv](../../sim/sources/ddr3_test/video_fifo_path_source.sv), [axi_2client_arbiter_tb.sv](../../sim/sources/ddr3_test/axi_2client_arbiter_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![shared_evidence_axi_tb](../../sim/images/shared_evidence_axi_tb.png)

## video_axi_client_edges_tb

用例源码：[video_axi_client_edges_tb.sv](../../sim/sources/ddr3_test/video_axi_client_edges_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![video_axi_client_edges_tb](../../sim/images/video_axi_client_edges_tb.png)

## video_axi_client_tb

用例源码：[video_axi_client_tb.sv](../../sim/sources/ddr3_test/video_axi_client_tb.sv), [axi_frame_slave_model.sv](../../sim/sources/ddr3_test/axi_frame_slave_model.sv)

历史VCD数据导出图（并非Vivado截图）：

![video_axi_client_tb](../../sim/images/video_axi_client_tb.png)

## video_memory_clear_cross_tb

用例源码：[video_memory_clear_cross_tb.sv](../../sim/sources/ddr3_test/video_memory_clear_cross_tb.sv), [axi_frame_slave_model.sv](../../sim/sources/ddr3_test/axi_frame_slave_model.sv)

历史VCD数据导出图（并非Vivado截图）：

![video_memory_clear_cross_tb](../../sim/images/video_memory_clear_cross_tb.png)

## video_memory_fabric_tb

用例源码：[video_memory_fabric_tb.sv](../../sim/sources/ddr3_test/video_memory_fabric_tb.sv), [axi_frame_slave_model.sv](../../sim/sources/ddr3_test/axi_frame_slave_model.sv)

历史VCD数据导出图（并非Vivado截图）：

![video_memory_fabric_tb](../../sim/images/video_memory_fabric_tb.png)
