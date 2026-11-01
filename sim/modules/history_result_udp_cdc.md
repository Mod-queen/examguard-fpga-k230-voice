# history_result_udp_cdc

当前工程实例化：否。关联1个自检用例。

| 用例 | 仿真器 | 当前结果 | 运行日志 | 结果记录 |
| --- | --- | --- | --- | --- |
| history_result_udp_cdc_tb | icarus | 通过 | [日志](../../sim/results/quality_current/history_result_udp_cdc_tb/run.log) | [记录](../../sim/results/quality_current/history_result_udp_cdc_tb/result.json) |

单独重跑本模块关联用例（工程根目录）：

```powershell
python sim/run_module_tests.py --only history_result_udp_cdc_tb --vivado-bin "$env:EXAMGUARD_VIVADO_BIN" --iverilog-bin "$env:EXAMGUARD_IVERILOG_BIN"
```

先按[复原说明](../../build/reproduction.md)配置工具。每次生成新的结果目录。

## history_result_udp_cdc_tb

用例源码：[history_result_udp_cdc_tb.sv](../../sim/sources/ddr3_test/history_result_udp_cdc_tb.sv)

VCD仿真波形（来源批次见索引）：

![history_result_udp_cdc_tb](../../sim/images/history_result_udp_cdc_tb.png)
