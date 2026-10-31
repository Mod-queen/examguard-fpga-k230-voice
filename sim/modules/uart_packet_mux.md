# uart_packet_mux

当前工程实例化：是。关联4个自检用例。

| 用例 | 仿真器 | 当前结果 | 运行日志 | 结果记录 |
| --- | --- | --- | --- | --- |
| camera_evidence_transport_tb | icarus | 通过 | [日志](../../sim/results/quality_current/camera_evidence_transport_tb/run.log) | [记录](../../sim/results/quality_current/camera_evidence_transport_tb/result.json) |
| transaction_uart_integration_tb | xsim | 通过 | [日志](../../sim/results/quality_current/transaction_uart_integration_tb/run.log) | [记录](../../sim/results/quality_current/transaction_uart_integration_tb/result.json) |
| uart_packet_mux_tb | icarus | 通过 | [日志](../../sim/results/quality_current/uart_packet_mux_tb/run.log) | [记录](../../sim/results/quality_current/uart_packet_mux_tb/result.json) |
| voice_uart_eight_tb | icarus | 通过 | [日志](../../sim/results/quality_current/voice_uart_eight_tb/run.log) | [记录](../../sim/results/quality_current/voice_uart_eight_tb/result.json) |

单独重跑本模块关联用例（工程根目录）：

```powershell
python sim/run_module_tests.py --only camera_evidence_transport_tb transaction_uart_integration_tb uart_packet_mux_tb voice_uart_eight_tb --vivado-bin "$env:EXAMGUARD_VIVADO_BIN" --iverilog-bin "$env:EXAMGUARD_IVERILOG_BIN"
```

先按[复原说明](../../build/reproduction.md)配置工具。每次生成新的结果目录。

## camera_evidence_transport_tb

用例源码：[camera_evidence_transport_tb.sv](../../sim/sources/ddr3_test/camera_evidence_transport_tb.sv), [axi_frame_slave_model.sv](../../sim/sources/ddr3_test/axi_frame_slave_model.sv)

历史VCD数据导出图（并非Vivado截图）：

![camera_evidence_transport_tb](../../sim/images/camera_evidence_transport_tb.png)

## transaction_uart_integration_tb

用例源码：[transaction_uart_integration_tb.sv](../../sim/sources/host_link/transaction_uart_integration_tb.sv)

本用例提供上方日志和机器可读结果；尚无截图，不用其他模块图片替代。

## uart_packet_mux_tb

用例源码：[uart_packet_mux_tb.sv](../../sim/sources/host_link/uart_packet_mux_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![uart_packet_mux_tb](../../sim/images/uart_packet_mux_tb.png)

## voice_uart_eight_tb

用例源码：[voice_uart_eight_tb.sv](../../sim/sources/voice_interaction/voice_uart_eight_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![voice_uart_eight_tb](../../sim/images/voice_uart_eight_tb.png)
