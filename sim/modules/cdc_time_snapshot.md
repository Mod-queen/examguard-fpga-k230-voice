# cdc_time_snapshot

当前工程实例化：是。关联5个自检用例。

| 用例 | 仿真器 | 当前结果 | 运行日志 | 结果记录 |
| --- | --- | --- | --- | --- |
| camera_evidence_transport_tb | icarus | 通过 | [日志](../../sim/results/quality_current/camera_evidence_transport_tb/run.log) | [记录](../../sim/results/quality_current/camera_evidence_transport_tb/result.json) |
| cdc_time_snapshot_tb | icarus | 通过 | [日志](../../sim/results/quality_current/cdc_time_snapshot_tb/run.log) | [记录](../../sim/results/quality_current/cdc_time_snapshot_tb/result.json) |
| evidence_capture_context_tb | icarus | 通过 | [日志](../../sim/results/quality_current/evidence_capture_context_tb/run.log) | [记录](../../sim/results/quality_current/evidence_capture_context_tb/result.json) |
| history_capture_client_tb | icarus | 通过 | [日志](../../sim/results/quality_current/history_capture_client_tb/run.log) | [记录](../../sim/results/quality_current/history_capture_client_tb/result.json) |
| video_memory_fabric_tb | xsim | 通过 | [日志](../../sim/results/quality_current/video_memory_fabric_tb/run.log) | [记录](../../sim/results/quality_current/video_memory_fabric_tb/result.json) |

单独重跑本模块关联用例（工程根目录）：

```powershell
python sim/run_module_tests.py --only camera_evidence_transport_tb cdc_time_snapshot_tb evidence_capture_context_tb history_capture_client_tb video_memory_fabric_tb --vivado-bin "$env:EXAMGUARD_VIVADO_BIN" --iverilog-bin "$env:EXAMGUARD_IVERILOG_BIN"
```

先按[复原说明](../../build/reproduction.md)配置工具。每次生成新的结果目录。

## camera_evidence_transport_tb

用例源码：[camera_evidence_transport_tb.sv](../../sim/sources/ddr3_test/camera_evidence_transport_tb.sv), [axi_frame_slave_model.sv](../../sim/sources/ddr3_test/axi_frame_slave_model.sv)

历史VCD数据导出图（并非Vivado截图）：

![camera_evidence_transport_tb](../../sim/images/camera_evidence_transport_tb.png)

## cdc_time_snapshot_tb

用例源码：[cdc_time_snapshot_tb.sv](../../sim/sources/event_identity/cdc_time_snapshot_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![cdc_time_snapshot_tb](../../sim/images/cdc_time_snapshot_tb.png)

## evidence_capture_context_tb

用例源码：[evidence_capture_context_tb.sv](../../sim/sources/ddr3_test/evidence_capture_context_tb.sv), [axi_frame_slave_model.sv](../../sim/sources/ddr3_test/axi_frame_slave_model.sv), [evidence_capture_context.v](../../sim/sources/ddr3_test/evidence_capture_context.v), [evidence_reset_epoch.v](../../sim/sources/event_identity/evidence_reset_epoch.v)

历史VCD数据导出图（并非Vivado截图）：

![evidence_capture_context_tb](../../sim/images/evidence_capture_context_tb.png)

## history_capture_client_tb

用例源码：[history_capture_client_tb.sv](../../sim/sources/ddr3_test/history_capture_client_tb.sv), [axi_frame_slave_model.sv](../../sim/sources/ddr3_test/axi_frame_slave_model.sv)

历史VCD数据导出图（并非Vivado截图）：

![history_capture_client_tb](../../sim/images/history_capture_client_tb.png)

## video_memory_fabric_tb

用例源码：[video_memory_fabric_tb.sv](../../sim/sources/ddr3_test/video_memory_fabric_tb.sv), [axi_frame_slave_model.sv](../../sim/sources/ddr3_test/axi_frame_slave_model.sv)

历史VCD数据导出图（并非Vivado截图）：

![video_memory_fabric_tb](../../sim/images/video_memory_fabric_tb.png)
