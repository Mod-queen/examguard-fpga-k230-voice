# DVP_Capture

当前工程实例化：是。关联2个自检用例。

| 用例 | 仿真器 | 当前结果 | 运行日志 | 结果记录 |
| --- | --- | --- | --- | --- |
| camera_capture_reset_tb | icarus | 通过 | [日志](../../sim/results/quality_current/camera_capture_reset_tb/run.log) | [记录](../../sim/results/quality_current/camera_capture_reset_tb/result.json) |
| dvp_capture_contract_tb | xsim | 通过 | [日志](../../sim/results/quality_current/dvp_capture_contract_tb/run.log) | [记录](../../sim/results/quality_current/dvp_capture_contract_tb/result.json) |

单独重跑本模块关联用例（工程根目录）：

```powershell
python sim/run_module_tests.py --only camera_capture_reset_tb dvp_capture_contract_tb --vivado-bin "$env:EXAMGUARD_VIVADO_BIN" --iverilog-bin "$env:EXAMGUARD_IVERILOG_BIN"
```

先按[复原说明](../../build/reproduction.md)配置工具。每次生成新的结果目录。

## camera_capture_reset_tb

用例源码：[camera_capture_reset_tb.sv](../../sim/sources/ddr3_test/camera_capture_reset_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![camera_capture_reset_tb](../../sim/images/camera_capture_reset_tb.png)

## dvp_capture_contract_tb

用例源码：[dvp_capture_contract_tb.sv](../../sim/sources/verification_20261031/dvp_capture_contract_tb.sv)

Vivado原生波形（与所列用例及WDB对应）：

![摄像头像素采样](../../sim/images/native_selected/03_dvp_pixel_final/vivado_wave.png)

[原始WDB](../../sim/native_databases/dvp_capture_contract_tb/focus_snapshot.wdb)

历史VCD数据导出图（并非Vivado截图）：

![dvp_capture_contract_tb](../../sim/images/dvp_capture_contract_tb.png)
