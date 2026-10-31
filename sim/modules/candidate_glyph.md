# candidate_glyph

当前工程实例化：否。关联3个自检用例。

| 用例 | 仿真器 | 当前结果 | 运行日志 | 结果记录 |
| --- | --- | --- | --- | --- |
| candidate_overlay_tb | icarus | 通过 | [日志](../../sim/results/quality_current/candidate_overlay_tb/run.log) | [记录](../../sim/results/quality_current/candidate_overlay_tb/result.json) |
| compact_identity_tb | icarus | 通过 | [日志](../../sim/results/quality_current/compact_identity_tb/run.log) | [记录](../../sim/results/quality_current/compact_identity_tb/result.json) |
| voice_interaction_system_tb | xsim | 通过 | [日志](../../sim/results/quality_current/voice_interaction_system_tb/run.log) | [记录](../../sim/results/quality_current/voice_interaction_system_tb/result.json) |

单独重跑本模块关联用例（工程根目录）：

```powershell
python sim/run_module_tests.py --only candidate_overlay_tb compact_identity_tb voice_interaction_system_tb --vivado-bin "$env:EXAMGUARD_VIVADO_BIN" --iverilog-bin "$env:EXAMGUARD_IVERILOG_BIN"
```

先按[复原说明](../../build/reproduction.md)配置工具。每次生成新的结果目录。

## candidate_overlay_tb

用例源码：[candidate_overlay_tb.sv](../../sim/sources/voice_interaction/candidate_overlay_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![candidate_overlay_tb](../../sim/images/candidate_overlay_tb.png)

## compact_identity_tb

用例源码：[compact_identity_tb.sv](../../sim/sources/vision_guard/compact_identity_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![compact_identity_tb](../../sim/images/compact_identity_tb.png)

## voice_interaction_system_tb

用例源码：[voice_interaction_system_tb.sv](../../sim/sources/voice_interaction/voice_interaction_system_tb.sv), [wonderecho_wire_model.sv](../../sim/sources/voice_interaction/wonderecho_wire_model.sv)

历史VCD数据导出图（并非Vivado截图）：

![voice_interaction_system_tb](../../sim/images/voice_interaction_system_tb.png)
