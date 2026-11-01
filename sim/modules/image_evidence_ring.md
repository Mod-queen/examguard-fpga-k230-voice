# image_evidence_ring

当前工程实例化：否。关联2个自检用例。

| 用例 | 仿真器 | 当前结果 | 运行日志 | 结果记录 |
| --- | --- | --- | --- | --- |
| image_evidence_capture_tb | icarus | 通过 | [日志](../../sim/results/quality_current/image_evidence_capture_tb/run.log) | [记录](../../sim/results/quality_current/image_evidence_capture_tb/result.json) |
| image_evidence_ring_tb | icarus | 通过 | [日志](../../sim/results/quality_current/image_evidence_ring_tb/run.log) | [记录](../../sim/results/quality_current/image_evidence_ring_tb/result.json) |

单独重跑本模块关联用例（工程根目录）：

```powershell
python sim/run_module_tests.py --only image_evidence_capture_tb image_evidence_ring_tb --vivado-bin "$env:EXAMGUARD_VIVADO_BIN" --iverilog-bin "$env:EXAMGUARD_IVERILOG_BIN"
```

先按[复原说明](../../build/reproduction.md)配置工具。每次生成新的结果目录。

## image_evidence_capture_tb

用例源码：[image_evidence_capture_tb.v](../../src/fpga/ov5640_ddr3_hdmi_vga.srcs/sources_1/image_evidence_ring/image_evidence_capture_tb.v)

VCD仿真波形（来源批次见索引）：

![image_evidence_capture_tb](../../sim/images/image_evidence_capture_tb.png)

## image_evidence_ring_tb

用例源码：[image_evidence_ring_tb.v](../../src/fpga/ov5640_ddr3_hdmi_vga.srcs/sources_1/image_evidence_ring/image_evidence_ring_tb.v)

VCD仿真波形（来源批次见索引）：

![image_evidence_ring_tb](../../sim/images/image_evidence_ring_tb.png)
