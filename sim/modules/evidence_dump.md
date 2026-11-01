# evidence_dump

当前工程实例化：是。关联2个自检用例。

| 用例 | 仿真器 | 当前结果 | 运行日志 | 结果记录 |
| --- | --- | --- | --- | --- |
| evidence_dump_tb | icarus | 通过 | [日志](../../sim/results/quality_current/evidence_dump_tb/run.log) | [记录](../../sim/results/quality_current/evidence_dump_tb/result.json) |
| transaction_uart_integration_tb | xsim | 通过 | [日志](../../sim/results/quality_current/transaction_uart_integration_tb/run.log) | [记录](../../sim/results/quality_current/transaction_uart_integration_tb/result.json) |

单独重跑本模块关联用例（工程根目录）：

```powershell
python sim/run_module_tests.py --only evidence_dump_tb transaction_uart_integration_tb --vivado-bin "$env:EXAMGUARD_VIVADO_BIN" --iverilog-bin "$env:EXAMGUARD_IVERILOG_BIN"
```

先按[复原说明](../../build/reproduction.md)配置工具。每次生成新的结果目录。

## evidence_dump_tb

用例源码：[evidence_dump_tb.v](../../src/fpga/ov5640_ddr3_hdmi_vga.srcs/sources_1/evidence_dump/evidence_dump_tb.v)

VCD仿真波形（来源批次见索引）：

![evidence_dump_tb](../../sim/images/evidence_dump_tb.png)

## transaction_uart_integration_tb

用例源码：[transaction_uart_integration_tb.sv](../../sim/sources/host_link/transaction_uart_integration_tb.sv)

本用例提供上方日志和机器可读结果；尚无截图，不用其他模块图片替代。
