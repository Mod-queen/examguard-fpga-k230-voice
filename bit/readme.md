# 当前烧录文件

本目录同时用于GitHub和代码压缩包。器件xc7a200tfbg484-2，Vivado2018.3；2026-11-01已固化并现场复测通过。

| 文件 | 用途 |
| --- | --- |
| examguard_current.bit | JTAG临时配置，等同本次Flash中程序版本 |
| current_full16m.mcs | 完整16MiB QSPI镜像，保留本板原语音尾区；供匹配本板布局时固化 |
| current_full16m.bin | 上述完整Flash的二进制形式，SHA与本轮整片读回一致 |
| current_spi1_payload.bin | FPGA SPI×1配置载荷，用于构造匹配的Flash布局 |

校验见[manifest](manifest.json)与[当前板卡版本](../board/current_release.json)。在Vivado硬件管理器选匹配器件与Flash型号；复原脚本不自动烧板。K230保持[SD自启动](../board/k230/readme.md)。
