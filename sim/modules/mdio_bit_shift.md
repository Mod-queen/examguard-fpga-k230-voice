# mdio_bit_shift

当前工程实例化：是。关联2个自检用例。

| 用例 | 仿真器 | 当前结果 | 运行日志 | 结果记录 |
| --- | --- | --- | --- | --- |
| mdio_readback_tb | xsim | 通过 | [日志](../../sim/results/quality_current/mdio_readback_tb/run.log) | [记录](../../sim/results/quality_current/mdio_readback_tb/result.json) |
| phy_qualification_tb | xsim | 通过 | [日志](../../sim/results/quality_current/phy_qualification_tb/run.log) | [记录](../../sim/results/quality_current/phy_qualification_tb/result.json) |

单独重跑本模块关联用例（工程根目录）：

```powershell
python sim/run_module_tests.py --only mdio_readback_tb phy_qualification_tb --vivado-bin "$env:EXAMGUARD_VIVADO_BIN" --iverilog-bin "$env:EXAMGUARD_IVERILOG_BIN"
```

先按[复原说明](../../build/reproduction.md)配置工具。每次生成新的结果目录。

## mdio_readback_tb

用例源码：[mdio_readback_tb.sv](../../sim/sources/host_link/mdio_readback_tb.sv)

VCD仿真波形（来源批次见索引）：

![mdio_readback_tb](../../sim/images/mdio_readback_tb.png)

## phy_qualification_tb

用例源码：[phy_qualification_tb.sv](../../sim/sources/host_link/phy_qualification_tb.sv), [rtl8211f_wire_model.sv](../../sim/sources/host_link/rtl8211f_wire_model.sv)

VCD仿真波形（来源批次见索引）：

![phy_qualification_tb](../../sim/images/phy_qualification_tb.png)
