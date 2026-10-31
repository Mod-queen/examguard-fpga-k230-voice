# 智察考场 双芯协同监考系统

K230提供身份与疑似目标识别，FPGA负责考试流程、显示、语音和事件前后图像保存，Python监考台负责回放和复核。Agent用于日常查询，JoyCode通过只读MCP组织自定义Skills、Rule和Prompt工作流。

这是AMD自主选题初级组的完整工程仓库，按指南推荐的src、sim、build、board、data、skill、report组织。中文说明保留在文件正文，仓库路径统一英文小写。当前包含163个模块的逐项验证导航、163个不同RTL自检用例和122项PC本地测试来源。

## 快速查看

- [按模块查看仿真、日志与波形](sim/readme.md)
- [环境与从零复原](build/reproduction.md)
- [摄像头、识别和复核算法说明](data/algorithms.md)
- [当前资源与时序原始报告](build/reports/quality_current/timing.rpt)
- [最新版原生资源图](sim/images/implementation/resources/vivado_utilization_summary.png) / [原生时序图](sim/images/implementation/timing/vivado_timing_summary.png)
- [技能包](skill/readme.md) / [报告与协作记录](report/readme.md) / [参赛要求对应](report/submission_map.md)

## 复原

已验证 **Vivado2018.3 build2405991**、Windows x64、Python3.12、Icarus12.0 devel，器件 **xc7a200tfbg484-2**。沿用2018.3以匹配现有板卡和IP；其他版本需自行重验。准备依赖与工具路径后：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/reproduce.ps1 -Mode full
```

仅核文件不加`-Mode full`；关键仿真用`-Mode quick`。工具可通过参数或环境变量配置，每次结果独立保存，不自动烧板。具体准备步骤见上方复原说明。

## 实现结果

| 指标 | 板上已验收版 | 本轮离线升级版 |
| --- | ---: | ---: |
| LUT | 41473 | 41440（30.97%） |
| 寄存器 | 44610 | 44643（16.68%） |
| BRAM | 70.5 | 70.5 |
| DSP | 3 | 3 |
| 建立余量WNS | +0.134ns | +0.374ns |
| 保持余量WHS | +0.031ns | +0.027ns |

升级集中在同步结构、网口管理时钟、高扇出复位和显示输出对齐，未改时钟预算或重训模型。163个不同RTL用例和122项PC测试通过；75,224条网络全部布线。剩余CDC结构与外部29输入/48输出预算如实保留，不把正裕量当全部接口签核。

板上位流、Flash读回与冷启记录见board/current_release.json。本轮升级候选见board/candidates/quality_status.json，尚未上板验收；两版不混用。仿真导航共有582条模块与测试关联，这不是代码覆盖率。

## 目录

| 目录 | 内容 |
| --- | --- |
| src | FPGA、K230、PC完整源码与IP配置 |
| sim | 单模块导航、脚本、实际日志、波形及截图 |
| build | 构建脚本、工具说明、原始资源与时序报告 |
| board | 位流、SD映射、运行配置与实测证据 |
| data | 算法说明、训练与来源记录 |
| skill | 可复用说明、提示流程与校验脚本 |
| report | 原模板设计报告、海报和协作记录；Word修订暂缓 |

团队原创贡献采用[MIT许可](license.txt)，上游代码、厂商IP与模型保留原条款，见[来源说明](third_party_notices.md)。仓库不含密钥、个人特征库或真实考试采集库。新用户须配置身份、实际连接与自己的模型账户。
