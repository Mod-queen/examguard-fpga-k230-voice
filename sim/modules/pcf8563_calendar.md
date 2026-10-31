# pcf8563_calendar

当前工程实例化：否。关联10个自检用例。

| 用例 | 仿真器 | 当前结果 | 运行日志 | 结果记录 |
| --- | --- | --- | --- | --- |
| i2c_register_master_tb | icarus | 通过 | [日志](../../sim/results/quality_current/i2c_register_master_tb/run.log) | [记录](../../sim/results/quality_current/i2c_register_master_tb/result.json) |
| maintenance_system_tb | xsim | 通过 | [日志](../../sim/results/quality_current/maintenance_system_tb/run.log) | [记录](../../sim/results/quality_current/maintenance_system_tb/result.json) |
| pcf8563_calendar_tb | icarus | 通过 | [日志](../../sim/results/quality_current/pcf8563_calendar_tb/run.log) | [记录](../../sim/results/quality_current/pcf8563_calendar_tb/result.json) |
| pcf8563_reader_tb | icarus | 通过 | [日志](../../sim/results/quality_current/pcf8563_reader_tb/run.log) | [记录](../../sim/results/quality_current/pcf8563_reader_tb/result.json) |
| pcf8563_setter_tb | xsim | 通过 | [日志](../../sim/results/quality_current/pcf8563_setter_tb/run.log) | [记录](../../sim/results/quality_current/pcf8563_setter_tb/result.json) |
| pcf8563_setter_wire_tb | icarus | 通过 | [日志](../../sim/results/quality_current/pcf8563_setter_wire_tb/run.log) | [记录](../../sim/results/quality_current/pcf8563_setter_wire_tb/result.json) |
| persistent_boot_service_tb | xsim | 通过 | [日志](../../sim/results/quality_current/persistent_boot_service_tb/run.log) | [记录](../../sim/results/quality_current/persistent_boot_service_tb/result.json) |
| persistent_maintenance_service_tb | icarus | 通过 | [日志](../../sim/results/quality_current/persistent_maintenance_service_tb/run.log) | [记录](../../sim/results/quality_current/persistent_maintenance_service_tb/result.json) |
| rtc_anchor_client_tb | icarus | 通过 | [日志](../../sim/results/quality_current/rtc_anchor_client_tb/run.log) | [记录](../../sim/results/quality_current/rtc_anchor_client_tb/result.json) |
| rtc_time_anchor_tb | icarus | 通过 | [日志](../../sim/results/quality_current/rtc_time_anchor_tb/run.log) | [记录](../../sim/results/quality_current/rtc_time_anchor_tb/result.json) |

单独重跑本模块关联用例（工程根目录）：

```powershell
python sim/run_module_tests.py --only i2c_register_master_tb maintenance_system_tb pcf8563_calendar_tb pcf8563_reader_tb pcf8563_setter_tb pcf8563_setter_wire_tb persistent_boot_service_tb persistent_maintenance_service_tb rtc_anchor_client_tb rtc_time_anchor_tb --vivado-bin "$env:EXAMGUARD_VIVADO_BIN" --iverilog-bin "$env:EXAMGUARD_IVERILOG_BIN"
```

先按[复原说明](../../build/reproduction.md)配置工具。每次生成新的结果目录。

## i2c_register_master_tb

用例源码：[i2c_register_master_tb.sv](../../sim/sources/persistence/i2c_register_master_tb.sv), [persistence_inventory_probe.sv](../../sim/sources/persistence/persistence_inventory_probe.sv)

历史VCD数据导出图（并非Vivado截图）：

![i2c_register_master_tb](../../sim/images/i2c_register_master_tb.png)

## maintenance_system_tb

用例源码：[maintenance_system_tb.sv](../../sim/test_repairs/maintenance_system_tb/maintenance_system_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![maintenance_system_tb](../../sim/images/maintenance_system_tb.png)

## pcf8563_calendar_tb

用例源码：[pcf8563_calendar_tb.sv](../../sim/sources/persistence/pcf8563_calendar_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![pcf8563_calendar_tb](../../sim/images/pcf8563_calendar_tb.png)

## pcf8563_reader_tb

用例源码：[pcf8563_reader_tb.sv](../../sim/sources/persistence/pcf8563_reader_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![pcf8563_reader_tb](../../sim/images/pcf8563_reader_tb.png)

## pcf8563_setter_tb

用例源码：[pcf8563_setter_tb.sv](../../sim/test_repairs/pcf8563_setter_tb/pcf8563_setter_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![pcf8563_setter_tb](../../sim/images/pcf8563_setter_tb.png)

## pcf8563_setter_wire_tb

用例源码：[pcf8563_setter_wire_tb.sv](../../sim/sources/persistence/pcf8563_setter_wire_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![pcf8563_setter_wire_tb](../../sim/images/pcf8563_setter_wire_tb.png)

## persistent_boot_service_tb

用例源码：[persistent_boot_service_tb.sv](../../sim/sources/persistence/persistent_boot_service_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![persistent_boot_service_tb](../../sim/images/persistent_boot_service_tb.png)

## persistent_maintenance_service_tb

用例源码：[persistent_maintenance_service_tb.sv](../../sim/sources/persistence/persistent_maintenance_service_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![persistent_maintenance_service_tb](../../sim/images/persistent_maintenance_service_tb.png)

## rtc_anchor_client_tb

用例源码：[rtc_anchor_client_tb.sv](../../sim/sources/persistence/rtc_anchor_client_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![rtc_anchor_client_tb](../../sim/images/rtc_anchor_client_tb.png)

## rtc_time_anchor_tb

用例源码：[rtc_time_anchor_tb.sv](../../sim/sources/persistence/rtc_time_anchor_tb.sv)

历史VCD数据导出图（并非Vivado截图）：

![rtc_time_anchor_tb](../../sim/images/rtc_time_anchor_tb.png)
