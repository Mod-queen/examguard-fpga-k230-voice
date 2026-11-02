# FPGA开发协作与可见交互节选

以下选取团队在开发过程中提出的实际要求。前三例的模型辅助部分是依据工程记录整理的摘要；第四例保留用户回传的模型答复节选。提示原文、整理摘要与验证输出分别标明。

## 例一 遮挡报警条件

团队提示原文节选：“我要求是当显示屏画面98%为黑色再触发”。团队随后明确该画面为“FPGA 外接 HDMI 屏幕”。

模型辅助摘要：核对有效像素范围、近黑阈值和连续帧条件，辅助调整局部实现及验证脚本。团队通过实物摆手和不透光遮挡测试确认策略。

验证输出：有效摄像区域内采用98%近黑比例、30帧确认和3帧释放；[720p仿真](../sim/results/quality_current/camera_black_720p_tb/run.log)、[边界仿真](../sim/results/quality_current/camera_black_boundary_tb/run.log)与[现场反馈](../board/verification/quality_field_acceptance.json)分别保留。

## 例二 连续报警和不同提示排队

团队提示原文节选：“还有当俩个报警同时遇到一起，语音助手只报警前一个”。

模型辅助摘要：对照队列等待时间、同类重复抑制和播报期间接收条件，辅助调整局部队列逻辑，并补充连续与混合请求测试。

团队现场确认原文：“没问题”。该反馈对应连续手机和手机紧接紫书的两项听音测试，相关[语音积压用例](../sim/results/current_voice/voice_notice_backlog_tb/run.log)和[回归汇总](../sim/results/current_voice/summary.json)可查看。

## 例三 FPGA优化和原生截图

团队提示原文节选：“你先把工程的升级到你认为的完美状态再开始截图”；“你的截图最好是vivado原生截图”。

模型辅助摘要：核对同步链与显示输出对齐，辅助局部实现、测试及构建脚本；从Vivado原始报告提取资源和时序数据，保存原生截图。采用版本由团队结合实际测试结果确认。

验证输出：同一目标器件与最终约束下，建立余量+0.134 ns→+0.374 ns；LUT 41473→41440，寄存器44610→44643。见[基线时序](../build/reports/accepted_current/timing.rpt)、[当前时序](../build/reports/quality_current/timing.rpt)、[基线资源](../build/reports/accepted_current/utilization.rpt)、[当前资源](../build/reports/quality_current/utilization.rpt)及[原生实现截图](../sim/images/implementation)。

## 例四 事件解释的交叉核对与修正

团队提示原文节选：“请核对 event_ref 为 00000001000000540000000100000000000000660000000000060be201003750 的事件，调用证据状态和图像工具，说明有哪些证据可以查看。”

模型初次答复节选：“该事件 event_code 为 0x66/102，属异常扭头类”。

根据工具字段核对后，模型答复改为：“event_uid 102”“event_code 80”“event_code_hex 0x50”“检测到手机 (0x50)”。编号102用于定位事件，类型由独立字段80/0x50确定。

落实结果：工具分别返回事件编号、类型码和名称；查询工作流要求按字段解释，未知类型继续核对。验证见[真实MCP子进程记录](../sim/original_logs/agent/mcp_event_metadata_result.json)和[复核技能](../skill/examguard_review/readme.md)。
