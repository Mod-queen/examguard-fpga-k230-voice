# 大模型辅助协作与工程验证

## 团队主导的工作

团队围绕FPGA主控确定作品需求、双摄分工、报警条件和演示流程，结合实物测试作出方案取舍，并完成现场操作与最终验收。作品主体是FPGA中的考试控制、图像采集、历史画面保存、接口通信和语音联动。

大模型作为开发辅助工具，用于资料检索、接口核对、代码与测试脚本辅助及结果整理。协作过程以“团队提出要求—辅助分析与实现—仿真和报告核对—实物验证—团队确认”为顺序，建议是否采用由团队结合实际结果决定。

## 1 遮挡检测围绕实际画面确定条件

团队明确提出：以FPGA外接HDMI摄像画面为依据，近黑比例达到98%再触发；同时要求正常摆手不产生遮挡提示。

模型辅助核对有效像素范围、近黑阈值和连续帧条件，并辅助调整局部实现与测试脚本。团队通过正常摆手、遮住OV5640和移开遮挡物进行实物验证，确认显示与语音表现后保留当前策略。

当前FPGA只统计有效摄像区域，RGB各通道不高于31计为近黑，达到98%并连续30帧确认，恢复3帧后释放。对应验证见[720p用例](../sim/results/quality_current/camera_black_720p_tb/run.log)、[边界用例](../sim/results/quality_current/camera_black_boundary_tb/run.log)及[现场记录](../board/verification/quality_field_acceptance.json)。

## 2 语音队列按连续报警场景完善

团队提出两项明确要求：同类报警再次发生时能够继续提示，不同报警接近发生时能够依次播出；随后完成连续手机、手机紧接紫书等实物测试。

模型辅助分析队列等待与重复抑制条件，辅助修改局部队列逻辑并补充回归脚本。实现中对同类待播请求合并，播报期间仍能接收后续提示，保留考试阶段与轮次约束。团队现场确认连续手机和不同类型提示均能正常播出。

验证见[语音积压用例](../sim/results/current_voice/voice_notice_backlog_tb/run.log)、[语音回归汇总](../sim/results/current_voice/summary.json)及[现场记录](../board/verification/quality_field_acceptance.json)。

## 3 用同一口径核对资源和时序

团队要求先完成工程优化，再保存Vivado原生资源、时序和模块波形图，并提供便于复现的脚本。

模型辅助检查同步链、显示数据与同步信号对齐、局部实现和构建脚本，并整理实现报告。优化对比沿用同一目标器件和最终约束口径；团队结合板端功能表现确定采用版本。

语音版基线至当前实现的建立余量由+0.134 ns提高到+0.374 ns，LUT由41473变为41440，寄存器由44610变为44643。改进重点是时序余量和信号对齐，资源变化见原始报告。对应[基线时序](../build/reports/accepted_current/timing.rpt)、[当前时序](../build/reports/quality_current/timing.rpt)、[基线资源](../build/reports/accepted_current/utilization.rpt)、[当前资源](../build/reports/quality_current/utilization.rpt)和[显示对齐验证](../sim/results/quality_current/display_pipeline_contract_tb/run.log)。

## 4 用工具字段复核模型解释

在事件检索协作中，曾出现把事件编号102换算成0x66后用于解释类型的回答。对照独立的类型字段后，修正为类型80，即0x50手机，并将编号、类型码和名称分开返回。该过程体现模型建议需要经过工具数据核对，再固化为接口与提示模板。

同一事件还分别记录证据总帧数、工具列出的图像数和实际发送给视觉模型的图像数，使解释与可查看范围一致。可见提示及答复节选见[交互记录](llm_visible_excerpts.md)，字段核对见[真实MCP子进程记录](../sim/original_logs/agent/mcp_event_metadata_result.json)。

## 5 FPGA证据上的智能复核功能

Agent和JoyCode是作品面向监考员的交互入口。FPGA持续负责考试流程、计时、语音执行与证据保存；上位机提供只读查询，大模型根据老师的问题检索并解释已有事件，老师结合原图完成复核。该运行功能与开发阶段的大模型辅助协作分别说明。

## 6 技能提炼与复用

[report_evidence](../skill/report_evidence/readme.md)由资源、时序与版本对应的核对流程提炼，通过来源清单、SHA和报告字段检查，帮助其他FPGA项目复用同一核查方法。

[examguard_review](../skill/examguard_review/readme.md)由事件字段、证据范围和图像数量的核对过程提炼，提供查询顺序、提示模板和工具契约，可用于具有类似事件与证据接口的设备复核。

两项技能均提供使用方法、适用范围、验证记录和失效条件。协作过程按工程记录整理，具体输出以所链接的仿真、实现报告及现场记录为依据。
