# 从零复原

已验证环境：Windows x64，Vivado **2018.3 build 2405991**，Artix-7器件支持，Python3.12，Icarus12.0 devel。器件xc7a200tfbg484-2。沿用2018.3是为了匹配现有MIG、FIFO、时钟与显示IP；复原以此工具版本为基准。

1. 将仓库放到英文路径，例如D:/examguard。安装Python3.12（含Tkinter）与pyserial；Vivado和Icarus按各自许可安装。新工具和缓存建议放D盘。
2. PowerShell设置一次工具位置（按本机路径修改）：

```powershell
$env:EXAMGUARD_PYTHON='D:\python\python.exe'
$env:EXAMGUARD_VIVADO_BIN='D:\vivado\vivado2018.3\Vivado\2018.3\bin'
$env:EXAMGUARD_IVERILOG_BIN='D:\iverilog\bin'
```

这些变量只影响当前终端；需要长期保存时可加入自己的终端配置。工具在PATH中时不必额外设置。新安装的路径可自由更换，不必复刻作者目录。

3. 只检查文件：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/reproduce.ps1
```

4. 关键模块仿真使用`-Mode quick`；全量测试、SD准备和FPGA构建使用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/reproduce.ps1 -Mode full
```

也可用原入口`reproduce.cmd --full --vivado-bin <bin目录> --iverilog-bin <bin目录>`。单独PC检查用`-Mode pc`，单独SD准备用`-Mode sd`。

5. 每次结果保存在新的build/reproduction_时间目录。脚本先核文件，再运行请求的步骤；任何失败停止并给出日志，不覆盖旧结果，不访问串口或自动烧板。日志内历史D:/fpga_race路径是当时来源，不是新机器依赖。
6. 新板连接、加载位流、准备SD和登记身份见[板端说明](../board/k230/readme.md)及[报告](../report/design_report.pdf)第三部分3.5。K230固件须匹配现有运行环境；固件与个人特征由使用者准备。PC模型连接使用自己的账户。运行`python tools/make_mcp_config.py`，将生成的`board/pc/mcp_follow_dashboard.json`导入JoyCode并启用examguard。生成脚本读取与监考台相同的storage_root；更换仓库或证据保存位置后重新生成一次，日常切换会话不需要修改。

## 位流与保存位置

根目录[bit](../bit/readme.md)集中保存当前已固化、冷启和现场复测版本的位流及Flash镜像；[版本指针](../board/current_release.json)关联哈希与验证记录。源码、实现报告与该bit一致。

PC的storage_root设置为D:/fpga_real/证据回溯，详见[目录配置](../board/pc/storage.md)。异机可改为自己的位置，确保接收、会话和回放采用同一配置。

## 结果检查

当前163个不同RTL用例见sim/readme.md；122项PC结果见sim/results/quality_pc/result.json。资源与时序的最新版为build/reports/quality_current，物理核对为quality_physical。历史文件不改写时间和验收范围。新版WNS+0.374ns、WHS+0.027ns；剩余CDC和外部29输入/48输出预算在qa/quality中保留。
