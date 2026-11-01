# 智察考场设计报告

[技术说明书 Word](design_report.docx) · [技术说明书 PDF](design_report.pdf)

2026年11月1日修订，共13页。保留技术文档模板的五部分结构，以FPGA考试控制、双摄分工、历史图像保存和模块验证为主线。系统框图见第3页，资源与时序对比见第9页；附录A说明大模型协作与技能包，附录B给出环境版本和复现步骤。

当前器件为Artix-7 xc7a200tfbg484-2，Vivado 2018.3 build 2405991。资源为41440 LUT、44643 FF、70.5 BRAM、3 DSP，建立余量+0.374 ns、保持余量+0.027 ns。报告区分实现分析、仿真、训练记录与现场功能验证。

当前硬件版本见[版本记录](../board/current_release.json)，原始实现数据见[实现报告](../build/reports/quality_current/timing.rpt)。[框图及选图](figures/revised_20261101/architecture.png)随报告保留。

工程背景资料：[双摄分工](../data/architecture.md)、[通信链路](../data/communication.md)、[视觉训练记录](../data/recognition.md)、[复核工作流](../data/review_workflow.md)。协作的可见记录另见[交互节选](llm_visible_excerpts.md)。中英文海报单独保留为PPTX。
