# voice_interaction_bus

当前工程实例化：是。关联2个自检用例。

| 用例 | 仿真器 | 当前结果 | 运行日志 | 结果记录 |
| --- | --- | --- | --- | --- |
| voice_interaction_bus_tb | icarus | 通过 | [日志](../../sim/results/quality_current/voice_interaction_bus_tb/run.log) | [记录](../../sim/results/quality_current/voice_interaction_bus_tb/result.json) |
| voice_interaction_system_tb | xsim | 通过 | [日志](../../sim/results/quality_current/voice_interaction_system_tb/run.log) | [记录](../../sim/results/quality_current/voice_interaction_system_tb/result.json) |

单独重跑本模块关联用例（工程根目录）：

```powershell
python sim/run_module_tests.py --only voice_interaction_bus_tb voice_interaction_system_tb --vivado-bin "$env:EXAMGUARD_VIVADO_BIN" --iverilog-bin "$env:EXAMGUARD_IVERILOG_BIN"
```

先按[复原说明](../../build/reproduction.md)配置工具。每次生成新的结果目录。

## voice_interaction_bus_tb

用例源码：[voice_interaction_bus_tb.sv](../../sim/sources/voice_interaction/voice_interaction_bus_tb.sv)

VCD仿真波形（来源批次见索引）：

![voice_interaction_bus_tb](../../sim/images/voice_interaction_bus_tb.png)

## voice_interaction_system_tb

用例源码：[voice_interaction_system_tb.sv](../../sim/sources/voice_interaction/voice_interaction_system_tb.sv), [wonderecho_wire_model.sv](../../sim/sources/voice_interaction/wonderecho_wire_model.sv)

VCD仿真波形（来源批次见索引）：

![voice_interaction_system_tb](../../sim/images/voice_interaction_system_tb.png)
