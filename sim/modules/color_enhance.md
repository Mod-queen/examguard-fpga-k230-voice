# color_enhance

当前工程实例化：是。关联2个自检用例。

| 用例 | 仿真器 | 当前结果 | 运行日志 | 结果记录 |
| --- | --- | --- | --- | --- |
| camera_black_driver_tb | xsim | 通过 | [日志](../../sim/results/quality_current/camera_black_driver_tb/run.log) | [记录](../../sim/results/quality_current/camera_black_driver_tb/result.json) |
| history_real_display_tb | xsim | 通过 | [日志](../../sim/results/quality_current/history_real_display_tb/run.log) | [记录](../../sim/results/quality_current/history_real_display_tb/result.json) |

单独重跑本模块关联用例（工程根目录）：

```powershell
python sim/run_module_tests.py --only camera_black_driver_tb history_real_display_tb --vivado-bin "$env:EXAMGUARD_VIVADO_BIN" --iverilog-bin "$env:EXAMGUARD_IVERILOG_BIN"
```

先按[复原说明](../../build/reproduction.md)配置工具。每次生成新的结果目录。

## camera_black_driver_tb

用例源码：[camera_black_driver_tb.sv](../../sim/sources/vision_guard/camera_black_driver_tb.sv)

VCD仿真波形（来源批次见索引）：

![camera_black_driver_tb](../../sim/images/camera_black_driver_tb.png)

## history_real_display_tb

用例源码：[history_real_display_tb.sv](../../sim/sources/ddr3_test/history_real_display_tb.sv)

VCD仿真波形（来源批次见索引）：

![history_real_display_tb](../../sim/images/history_real_display_tb.png)
