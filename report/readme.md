# 智察考场设计报告

[技术说明书 Word](design_report.docx) · [技术说明书 PDF](design_report.pdf)

2026年11月2日修订，共14页。沿用原技术文档模板的五部分结构、页眉页脚与正文风格。前两页集中展示用途、指标和创新点；系统框图见第3页，硬件连接及外设见第4至6页，软件与智能复核流程见第7页，上位机见第8页，模块仿真见第9页，资源与时序对比见第10页。视觉记录见第11页；3.4大模型协作与技能包、3.5从零复现说明分别见第12、13页。第四部分总结和参考文献见第14页。

当前器件为Artix-7 xc7a200tfbg484-2，Vivado 2018.3 build 2405991。资源为41440 LUT、44643 FF、70.5 BRAM、3 DSP，建立余量+0.374 ns、保持余量+0.027 ns。报告区分实现分析、仿真、训练记录与现场功能验证。

当前硬件版本见[版本记录](../board/current_release.json)，原始实现数据见[实现报告](../build/reports/quality_current/timing.rpt)。[框图及选图](figures/revised_20261101/architecture.png)随报告保留。

工程背景资料：[双摄分工](../data/architecture.md)、[通信链路](../data/communication.md)、[视觉训练记录](../data/recognition.md)、[复核工作流](../data/review_workflow.md)。协作的可见记录另见[交互节选](llm_visible_excerpts.md)。[中英文海报](amd_poster_zh_en.pptx)共两页，直接填充AMD原模板，保留简介栏、竖排设计与结果栏目、圆角说明框和AMD标识。已加入学校校徽、真实样机、系统框图、资源时序表及测试汇总表。测试表区分163项RTL自检记录、122项PC本地回归、16 MiB Flash读回和现场功能复测。
