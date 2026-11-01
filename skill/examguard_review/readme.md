# 考场证据复核技能

适用场景：通过已连接的examguard MCP查询疑似事件、证据状态及最后系统状态，也可明确选择历史场次复核。该技能不修改硬件、不训练模型，最终由老师查看原始证据判断。

## 使用方法

将[skill.md](skill.md)正文导入平台技能配置；完整目录导入时保留[工具契约](references/tool_contract.md)。仓库按指南使用小写文件名；本目录不是所有客户端都能自动发现的全局技能目录。

配套[Rule](../../board/pc/agent_rule.md)与[Prompt](../../board/pc/agent_prompt.txt)只关联本复核助手。先按[复现说明](../../build/reproduction.md)生成本机MCP配置，在平台导入并启用examguard，再由监考台选择会话。

## 来源观察与纠错

已保留的可见交互发现两类问题：一是将UID102换算为0x66后误作事件类型，二是将所选范围没有图像扩大解释为设备从未采集或网络丢包。由此提炼先确认来源、只读类型字段、区分完整性与原因、区分列表和实际看图范围的查询流程。

[可见交互节选](../../report/llm_visible_excerpts.md)保留请求、回答与修正；[真实MCP子进程记录](../../sim/original_logs/agent/mcp_event_metadata_result.json)核对UID102对应80/0x50手机，数据库前后SHA一致。用户回传的平台答复和本地工具回归分别保留，不混作同一种测试。

## 验证效果和复现

接口的范围、缺失、完整和冲突语义由[src/pc/host/app/test_agent.py](../../src/pc/host/app/test_agent.py)核对；JoyCode会话跟随由[test_agent_joycode.py](../../src/pc/host/app/test_agent_joycode.py)核对。已保存的122项PC回归结果见[result.json](../../sim/results/quality_pc/result.json)。从根目录运行`powershell -ExecutionPolicy Bypass -File tools/reproduce.ps1 -Mode pc`可重新检查本地软件，不访问云模型或板卡。

## 失效条件与迁移

MCP未连接、来源选择错误、接口参数变化或证据冲突时停止给出完整性结论。只有路径元数据时不能声称已经看图；历史状态不能证明当前在线。迁移到其他设备告警场景时，替换事件表与工具契约，重新检查查询范围和回归结果。本技能不是PYNQ专用技能。
