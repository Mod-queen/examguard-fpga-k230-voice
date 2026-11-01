# crc32_d8

当前工程实例化：是。关联4个自检用例。

| 用例 | 仿真器 | 当前结果 | 运行日志 | 结果记录 |
| --- | --- | --- | --- | --- |
| camera_evidence_transport_tb | icarus | 通过 | [日志](../../sim/results/quality_current/camera_evidence_transport_tb/run.log) | [记录](../../sim/results/quality_current/camera_evidence_transport_tb/result.json) |
| network_isolation_tb | icarus | 通过 | [日志](../../sim/results/quality_current/network_isolation_tb/run.log) | [记录](../../sim/results/quality_current/network_isolation_tb/result.json) |
| queued_window_packet_tb | xsim | 通过 | [日志](../../sim/results/quality_current/queued_window_packet_tb/run.log) | [记录](../../sim/results/quality_current/queued_window_packet_tb/result.json) |
| video_memory_fabric_tb | xsim | 通过 | [日志](../../sim/results/quality_current/video_memory_fabric_tb/run.log) | [记录](../../sim/results/quality_current/video_memory_fabric_tb/result.json) |

单独重跑本模块关联用例（工程根目录）：

```powershell
python sim/run_module_tests.py --only camera_evidence_transport_tb network_isolation_tb queued_window_packet_tb video_memory_fabric_tb --vivado-bin "$env:EXAMGUARD_VIVADO_BIN" --iverilog-bin "$env:EXAMGUARD_IVERILOG_BIN"
```

先按[复原说明](../../build/reproduction.md)配置工具。每次生成新的结果目录。

## camera_evidence_transport_tb

用例源码：[camera_evidence_transport_tb.sv](../../sim/sources/ddr3_test/camera_evidence_transport_tb.sv), [axi_frame_slave_model.sv](../../sim/sources/ddr3_test/axi_frame_slave_model.sv)

VCD仿真波形（来源批次见索引）：

![camera_evidence_transport_tb](../../sim/images/camera_evidence_transport_tb.png)

## network_isolation_tb

用例源码：[network_isolation_tb.sv](../../sim/sources/ddr3_test/network_isolation_tb.sv)

VCD仿真波形（来源批次见索引）：

![network_isolation_tb](../../sim/images/network_isolation_tb.png)

## queued_window_packet_tb

用例源码：[queued_window_packet_tb.sv](../../sim/sources/ddr3_test/queued_window_packet_tb.sv), [axi_frame_slave_model.sv](../../sim/sources/ddr3_test/axi_frame_slave_model.sv)

VCD仿真波形（来源批次见索引）：

![queued_window_packet_tb](../../sim/images/queued_window_packet_tb.png)

## video_memory_fabric_tb

用例源码：[video_memory_fabric_tb.sv](../../sim/sources/ddr3_test/video_memory_fabric_tb.sv), [axi_frame_slave_model.sv](../../sim/sources/ddr3_test/axi_frame_slave_model.sv)

VCD仿真波形（来源批次见索引）：

![video_memory_fabric_tb](../../sim/images/video_memory_fabric_tb.png)
