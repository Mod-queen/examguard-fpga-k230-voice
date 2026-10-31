# cdc_event_transaction

当前工程实例化：是。关联15个自检用例。

| 用例 | 仿真器 | 当前结果 | 运行日志 | 结果记录 |
| --- | --- | --- | --- | --- |
| board_monitor_system_tb | xsim | 通过 | [日志](../../sim/results/quality_current/board_monitor_system_tb/run.log) | [记录](../../sim/results/quality_current/board_monitor_system_tb/result.json) |
| camera_evidence_transport_tb | icarus | 通过 | [日志](../../sim/results/quality_current/camera_evidence_transport_tb/run.log) | [记录](../../sim/results/quality_current/camera_evidence_transport_tb/result.json) |
| cdc_event_transaction_tb | icarus | 通过 | [日志](../../sim/results/quality_current/cdc_event_transaction_tb/run.log) | [记录](../../sim/results/quality_current/cdc_event_transaction_tb/result.json) |
| cdc_stats_snapshot_tb | icarus | 通过 | [日志](../../sim/results/quality_current/cdc_stats_snapshot_tb/run.log) | [记录](../../sim/results/quality_current/cdc_stats_snapshot_tb/result.json) |
| cdc_time_snapshot_tb | icarus | 通过 | [日志](../../sim/results/quality_current/cdc_time_snapshot_tb/run.log) | [记录](../../sim/results/quality_current/cdc_time_snapshot_tb/result.json) |
| event_cdc_evidence_tb | xsim | 通过 | [日志](../../sim/results/quality_current/event_cdc_evidence_tb/run.log) | [记录](../../sim/results/quality_current/event_cdc_evidence_tb/result.json) |
| evidence_capture_context_tb | icarus | 通过 | [日志](../../sim/results/quality_current/evidence_capture_context_tb/run.log) | [记录](../../sim/results/quality_current/evidence_capture_context_tb/result.json) |
| evidence_health_telemetry_tb | xsim | 通过 | [日志](../../sim/results/quality_current/evidence_health_telemetry_tb/run.log) | [记录](../../sim/results/quality_current/evidence_health_telemetry_tb/result.json) |
| evidence_reset_epoch_tb | icarus | 通过 | [日志](../../sim/results/quality_current/evidence_reset_epoch_tb/run.log) | [记录](../../sim/results/quality_current/evidence_reset_epoch_tb/result.json) |
| history_capture_client_tb | icarus | 通过 | [日志](../../sim/results/quality_current/history_capture_client_tb/run.log) | [记录](../../sim/results/quality_current/history_capture_client_tb/result.json) |
| history_health_stats_tb | icarus | 通过 | [日志](../../sim/results/quality_current/history_health_stats_tb/run.log) | [记录](../../sim/results/quality_current/history_health_stats_tb/result.json) |
| history_top_interconnect_tb | xsim | 通过 | [日志](../../sim/results/quality_current/history_top_interconnect_tb/run.log) | [记录](../../sim/results/quality_current/history_top_interconnect_tb/result.json) |
| phy_health_snapshot_tb | xsim | 通过 | [日志](../../sim/results/quality_current/phy_health_snapshot_tb/run.log) | [记录](../../sim/results/quality_current/phy_health_snapshot_tb/result.json) |
| video_memory_fabric_tb | xsim | 通过 | [日志](../../sim/results/quality_current/video_memory_fabric_tb/run.log) | [记录](../../sim/results/quality_current/video_memory_fabric_tb/result.json) |
| voice_interaction_system_tb | xsim | 通过 | [日志](../../sim/results/quality_current/voice_interaction_system_tb/run.log) | [记录](../../sim/results/quality_current/voice_interaction_system_tb/result.json) |

单独重跑本模块关联用例（工程根目录）：

```powershell
python sim/run_module_tests.py --only board_monitor_system_tb camera_evidence_transport_tb cdc_event_transaction_tb cdc_stats_snapshot_tb cdc_time_snapshot_tb event_cdc_evidence_tb evidence_capture_context_tb evidence_health_telemetry_tb evidence_reset_epoch_tb history_capture_client_tb history_health_stats_tb history_top_interconnect_tb phy_health_snapshot_tb video_memory_fabric_tb voice_interaction_system_tb --vivado-bin "$env:EXAMGUARD_VIVADO_BIN" --iverilog-bin "$env:EXAMGUARD_IVERILOG_BIN"
```

先按[复原说明](../../build/reproduction.md)配置工具。每次生成新的结果目录。

## board_monitor_system_tb

用例源码：[board_monitor_system_tb.sv](../../sim/test_repairs/board_monitor_system_tb/board_monitor_system_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![board_monitor_system_tb](../../sim/images/board_monitor_system_tb.png)

## camera_evidence_transport_tb

用例源码：[camera_evidence_transport_tb.sv](../../sim/sources/ddr3_test/camera_evidence_transport_tb.sv), [axi_frame_slave_model.sv](../../sim/sources/ddr3_test/axi_frame_slave_model.sv)

历史VCD数据导出图（并非Vivado截图）：

![camera_evidence_transport_tb](../../sim/images/camera_evidence_transport_tb.png)

## cdc_event_transaction_tb

用例源码：[cdc_event_transaction_tb.sv](../../sim/sources/event_identity/cdc_event_transaction_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![cdc_event_transaction_tb](../../sim/images/cdc_event_transaction_tb.png)

## cdc_stats_snapshot_tb

用例源码：[cdc_stats_snapshot_tb.sv](../../sim/sources/health/cdc_stats_snapshot_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![cdc_stats_snapshot_tb](../../sim/images/cdc_stats_snapshot_tb.png)

## cdc_time_snapshot_tb

用例源码：[cdc_time_snapshot_tb.sv](../../sim/sources/event_identity/cdc_time_snapshot_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![cdc_time_snapshot_tb](../../sim/images/cdc_time_snapshot_tb.png)

## event_cdc_evidence_tb

用例源码：[event_cdc_evidence_tb.sv](../../sim/sources/ddr3_test/event_cdc_evidence_tb.sv), [axi_frame_slave_model.sv](../../sim/sources/ddr3_test/axi_frame_slave_model.sv)

历史VCD数据导出图（并非Vivado截图）：

![event_cdc_evidence_tb](../../sim/images/event_cdc_evidence_tb.png)

## evidence_capture_context_tb

用例源码：[evidence_capture_context_tb.sv](../../sim/sources/ddr3_test/evidence_capture_context_tb.sv), [axi_frame_slave_model.sv](../../sim/sources/ddr3_test/axi_frame_slave_model.sv), [evidence_capture_context.v](../../sim/sources/ddr3_test/evidence_capture_context.v), [evidence_reset_epoch.v](../../sim/sources/event_identity/evidence_reset_epoch.v)

历史VCD数据导出图（并非Vivado截图）：

![evidence_capture_context_tb](../../sim/images/evidence_capture_context_tb.png)

## evidence_health_telemetry_tb

用例源码：[evidence_health_telemetry_tb.sv](../../sim/sources/health/evidence_health_telemetry_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![evidence_health_telemetry_tb](../../sim/images/evidence_health_telemetry_tb.png)

## evidence_reset_epoch_tb

用例源码：[evidence_reset_epoch_tb.sv](../../sim/sources/event_identity/evidence_reset_epoch_tb.sv), [evidence_reset_epoch.v](../../sim/sources/event_identity/evidence_reset_epoch.v)

历史VCD数据导出图（并非Vivado截图）：

![evidence_reset_epoch_tb](../../sim/images/evidence_reset_epoch_tb.png)

## history_capture_client_tb

用例源码：[history_capture_client_tb.sv](../../sim/sources/ddr3_test/history_capture_client_tb.sv), [axi_frame_slave_model.sv](../../sim/sources/ddr3_test/axi_frame_slave_model.sv)

历史VCD数据导出图（并非Vivado截图）：

![history_capture_client_tb](../../sim/images/history_capture_client_tb.png)

## history_health_stats_tb

用例源码：[history_health_stats_tb.sv](../../sim/sources/health/history_health_stats_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![history_health_stats_tb](../../sim/images/history_health_stats_tb.png)

## history_top_interconnect_tb

用例源码：[history_top_interconnect_tb.sv](../../sim/sources/ddr3_test/history_top_interconnect_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![history_top_interconnect_tb](../../sim/images/history_top_interconnect_tb.png)

## phy_health_snapshot_tb

用例源码：[phy_health_snapshot_tb.sv](../../sim/sources/health/phy_health_snapshot_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![phy_health_snapshot_tb](../../sim/images/phy_health_snapshot_tb.png)

## video_memory_fabric_tb

用例源码：[video_memory_fabric_tb.sv](../../sim/sources/ddr3_test/video_memory_fabric_tb.sv), [axi_frame_slave_model.sv](../../sim/sources/ddr3_test/axi_frame_slave_model.sv)

历史VCD数据导出图（并非Vivado截图）：

![video_memory_fabric_tb](../../sim/images/video_memory_fabric_tb.png)

## voice_interaction_system_tb

用例源码：[voice_interaction_system_tb.sv](../../sim/sources/voice_interaction/voice_interaction_system_tb.sv), [wonderecho_wire_model.sv](../../sim/sources/voice_interaction/wonderecho_wire_model.sv)

历史VCD数据导出图（并非Vivado截图）：

![voice_interaction_system_tb](../../sim/images/voice_interaction_system_tb.png)
