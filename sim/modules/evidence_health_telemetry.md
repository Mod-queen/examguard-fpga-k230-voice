# evidence_health_telemetry

当前工程实例化：是。关联3个自检用例。

| 用例 | 仿真器 | 当前结果 | 运行日志 | 结果记录 |
| --- | --- | --- | --- | --- |
| camera_evidence_transport_tb | icarus | 通过 | [日志](../../sim/results/quality_current/camera_evidence_transport_tb/run.log) | [记录](../../sim/results/quality_current/camera_evidence_transport_tb/result.json) |
| evidence_health_telemetry_tb | xsim | 通过 | [日志](../../sim/results/quality_current/evidence_health_telemetry_tb/run.log) | [记录](../../sim/results/quality_current/evidence_health_telemetry_tb/result.json) |
| history_health_stats_tb | icarus | 通过 | [日志](../../sim/results/quality_current/history_health_stats_tb/run.log) | [记录](../../sim/results/quality_current/history_health_stats_tb/result.json) |

单独重跑本模块关联用例（工程根目录）：

```powershell
python sim/run_module_tests.py --only camera_evidence_transport_tb evidence_health_telemetry_tb history_health_stats_tb --vivado-bin "$env:EXAMGUARD_VIVADO_BIN" --iverilog-bin "$env:EXAMGUARD_IVERILOG_BIN"
```

先按[复原说明](../../build/reproduction.md)配置工具。每次生成新的结果目录。

## camera_evidence_transport_tb

用例源码：[camera_evidence_transport_tb.sv](../../sim/sources/ddr3_test/camera_evidence_transport_tb.sv), [axi_frame_slave_model.sv](../../sim/sources/ddr3_test/axi_frame_slave_model.sv)

历史VCD数据导出图（并非Vivado截图）：

![camera_evidence_transport_tb](../../sim/images/camera_evidence_transport_tb.png)

## evidence_health_telemetry_tb

用例源码：[evidence_health_telemetry_tb.sv](../../sim/sources/health/evidence_health_telemetry_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![evidence_health_telemetry_tb](../../sim/images/evidence_health_telemetry_tb.png)

## history_health_stats_tb

用例源码：[history_health_stats_tb.sv](../../sim/sources/health/history_health_stats_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![history_health_stats_tb](../../sim/images/history_health_stats_tb.png)
