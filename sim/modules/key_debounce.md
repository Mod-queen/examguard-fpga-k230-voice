# key_debounce

当前工程实例化：是。关联2个自检用例。

| 用例 | 仿真器 | 当前结果 | 运行日志 | 结果记录 |
| --- | --- | --- | --- | --- |
| key_debounce_tb | icarus | 通过 | [日志](../../sim/results/quality_current/key_debounce_tb/run.log) | [记录](../../sim/results/quality_current/key_debounce_tb/result.json) |
| operator_alarm_contract_tb | xsim | 通过 | [日志](../../sim/results/quality_current/operator_alarm_contract_tb/run.log) | [记录](../../sim/results/quality_current/operator_alarm_contract_tb/result.json) |

单独重跑本模块关联用例（工程根目录）：

```powershell
python sim/run_module_tests.py --only key_debounce_tb operator_alarm_contract_tb --vivado-bin "$env:EXAMGUARD_VIVADO_BIN" --iverilog-bin "$env:EXAMGUARD_IVERILOG_BIN"
```

先按[复原说明](../../build/reproduction.md)配置工具。每次生成新的结果目录。

## key_debounce_tb

用例源码：[key_debounce_tb.v](../../src/fpga/ov5640_ddr3_hdmi_vga.srcs/sources_1/user_control/key_debounce_tb.v)

VCD仿真波形（来源批次见索引）：

![key_debounce_tb](../../sim/images/key_debounce_tb.png)

## operator_alarm_contract_tb

用例源码：[operator_alarm_contract_tb.sv](../../sim/sources/verification_20261031/operator_alarm_contract_tb.sv)

VCD仿真波形（来源批次见索引）：

![operator_alarm_contract_tb](../../sim/images/operator_alarm_contract_tb.png)
