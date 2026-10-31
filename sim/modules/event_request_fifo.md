# event_request_fifo

当前工程实例化：是。关联10个自检用例。

| 用例 | 仿真器 | 当前结果 | 运行日志 | 结果记录 |
| --- | --- | --- | --- | --- |
| camera_evidence_transport_tb | icarus | 通过 | [日志](../../sim/results/quality_current/camera_evidence_transport_tb/run.log) | [记录](../../sim/results/quality_current/camera_evidence_transport_tb/result.json) |
| event_cdc_evidence_tb | xsim | 通过 | [日志](../../sim/results/quality_current/event_cdc_evidence_tb/run.log) | [记录](../../sim/results/quality_current/event_cdc_evidence_tb/result.json) |
| event_identity_queue_tb | xsim | 通过 | [日志](../../sim/results/quality_current/event_identity_queue_tb/run.log) | [记录](../../sim/results/quality_current/event_identity_queue_tb/result.json) |
| event_request_fifo_optimized_tb | icarus | 通过 | [日志](../../sim/results/quality_current/event_request_fifo_optimized_tb/run.log) | [记录](../../sim/results/quality_current/event_request_fifo_optimized_tb/result.json) |
| event_request_fifo_tb | icarus | 通过 | [日志](../../sim/results/quality_current/event_request_fifo_tb/run.log) | [记录](../../sim/results/quality_current/event_request_fifo_tb/result.json) |
| event_transaction_queue_tb | icarus | 通过 | [日志](../../sim/results/quality_current/event_transaction_queue_tb/run.log) | [记录](../../sim/results/quality_current/event_transaction_queue_tb/result.json) |
| exam_event_context_tb | icarus | 通过 | [日志](../../sim/results/quality_current/exam_event_context_tb/run.log) | [记录](../../sim/results/quality_current/exam_event_context_tb/result.json) |
| persistent_boot_service_tb | xsim | 通过 | [日志](../../sim/results/quality_current/persistent_boot_service_tb/run.log) | [记录](../../sim/results/quality_current/persistent_boot_service_tb/result.json) |
| persistent_event_identity_tb | icarus | 通过 | [日志](../../sim/results/quality_current/persistent_event_identity_tb/run.log) | [记录](../../sim/results/quality_current/persistent_event_identity_tb/result.json) |
| transaction_uart_integration_tb | xsim | 通过 | [日志](../../sim/results/quality_current/transaction_uart_integration_tb/run.log) | [记录](../../sim/results/quality_current/transaction_uart_integration_tb/result.json) |

单独重跑本模块关联用例（工程根目录）：

```powershell
python sim/run_module_tests.py --only camera_evidence_transport_tb event_cdc_evidence_tb event_identity_queue_tb event_request_fifo_optimized_tb event_request_fifo_tb event_transaction_queue_tb exam_event_context_tb persistent_boot_service_tb persistent_event_identity_tb transaction_uart_integration_tb --vivado-bin "$env:EXAMGUARD_VIVADO_BIN" --iverilog-bin "$env:EXAMGUARD_IVERILOG_BIN"
```

先按[复原说明](../../build/reproduction.md)配置工具。每次生成新的结果目录。

## camera_evidence_transport_tb

用例源码：[camera_evidence_transport_tb.sv](../../sim/sources/ddr3_test/camera_evidence_transport_tb.sv), [axi_frame_slave_model.sv](../../sim/sources/ddr3_test/axi_frame_slave_model.sv)

历史VCD数据导出图（并非Vivado截图）：

![camera_evidence_transport_tb](../../sim/images/camera_evidence_transport_tb.png)

## event_cdc_evidence_tb

用例源码：[event_cdc_evidence_tb.sv](../../sim/sources/ddr3_test/event_cdc_evidence_tb.sv), [axi_frame_slave_model.sv](../../sim/sources/ddr3_test/axi_frame_slave_model.sv)

历史VCD数据导出图（并非Vivado截图）：

![event_cdc_evidence_tb](../../sim/images/event_cdc_evidence_tb.png)

## event_identity_queue_tb

用例源码：[event_identity_queue_tb.sv](../../sim/sources/event_identity/event_identity_queue_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![event_identity_queue_tb](../../sim/images/event_identity_queue_tb.png)

## event_request_fifo_optimized_tb

用例源码：[event_request_fifo_optimized_tb.sv](../../sim/sources/verification_20261031/event_request_fifo_optimized_tb.sv)

Vivado原生波形（与所列用例及WDB对应）：

![队列满与顺序保持](../../sim/images/native_selected/05_fifo_full_clean/vivado_wave.png)

[原始WDB](../../sim/native_databases/event_request_fifo_optimized_tb/focus_snapshot.wdb)

历史VCD数据导出图（并非Vivado截图）：

![event_request_fifo_optimized_tb](../../sim/images/event_request_fifo_optimized_tb.png)

## event_request_fifo_tb

用例源码：[event_request_fifo_tb.sv](../../sim/sources/event_request_fifo/event_request_fifo_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![event_request_fifo_tb](../../sim/images/event_request_fifo_tb.png)

## event_transaction_queue_tb

用例源码：[event_transaction_queue_tb.sv](../../sim/sources/event_transaction_queue/event_transaction_queue_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![event_transaction_queue_tb](../../sim/images/event_transaction_queue_tb.png)

## exam_event_context_tb

用例源码：[exam_event_context_tb.sv](../../sim/sources/event_identity/exam_event_context_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![exam_event_context_tb](../../sim/images/exam_event_context_tb.png)

## persistent_boot_service_tb

用例源码：[persistent_boot_service_tb.sv](../../sim/sources/persistence/persistent_boot_service_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![persistent_boot_service_tb](../../sim/images/persistent_boot_service_tb.png)

## persistent_event_identity_tb

用例源码：[persistent_event_identity_tb.sv](../../sim/sources/event_identity/persistent_event_identity_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![persistent_event_identity_tb](../../sim/images/persistent_event_identity_tb.png)

## transaction_uart_integration_tb

用例源码：[transaction_uart_integration_tb.sv](../../sim/sources/host_link/transaction_uart_integration_tb.sv)

本用例提供上方日志和机器可读结果；尚无截图，不用其他模块图片替代。
