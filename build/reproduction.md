# 从零复原

已验证环境：Windows x64，Vivado **2018.3 build 2405991**，Artix-7器件支持，Python3.12，Icarus12.0 devel。器件xc7a200tfbg484-2。沿用2018.3是为了匹配现有MIG、FIFO、时钟与显示IP；这是对指南其他版本说明要求的明确声明，未宣称新版本已验证。

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
6. 新板连接、加载位流、准备SD和登记身份见board/k230/readme.md及report附录。K230固件须匹配现有运行环境；固件与个人特征由使用者准备。PC模型连接使用自己的账户。生成实际MCP配置后重连JoyCode。

## 位流选择

board/current_release.json指向已现场验收的语音版本及其Flash镜像；board/candidates/quality_status.json指向本轮离线升级候选。不要把候选源码复原成功当成已完成现场验收，也不要直接把候选bit与旧Flash镜像混用。

## 结果检查

当前163个不同RTL用例见sim/readme.md；122项PC结果见sim/results/quality_pc/result.json。资源与时序的最新版为build/reports/quality_current，物理核对为quality_physical。历史文件不改写时间和验收范围。新版WNS+0.374ns、WHS+0.027ns；剩余CDC和外部29输入/48输出预算在qa/quality中保留。
