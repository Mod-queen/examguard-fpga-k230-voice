# fullscreen_monitor

当前工程实例化：是。关联1个自检用例。

| 用例 | 仿真器 | 当前结果 | 运行日志 | 结果记录 |
| --- | --- | --- | --- | --- |
| fullscreen_monitor_tb | icarus | 通过 | [日志](../../sim/results/quality_current/fullscreen_monitor_tb/run.log) | [记录](../../sim/results/quality_current/fullscreen_monitor_tb/result.json) |

单独重跑本模块关联用例（工程根目录）：

```powershell
python sim/run_module_tests.py --only fullscreen_monitor_tb --vivado-bin "$env:EXAMGUARD_VIVADO_BIN" --iverilog-bin "$env:EXAMGUARD_IVERILOG_BIN"
```

先按[复原说明](../../build/reproduction.md)配置工具。每次生成新的结果目录。

## fullscreen_monitor_tb

用例源码：[fullscreen_monitor_tb.v](../../src/fpga/ov5640_ddr3_hdmi_vga.srcs/sources_1/fullscreen_monitor/fullscreen_monitor_tb.v)

VCD仿真波形（来源批次见索引）：

![fullscreen_monitor_tb](../../sim/images/fullscreen_monitor_tb.png)
