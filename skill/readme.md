# 技能包说明

report_evidence：可用于其他FPGA题目的报告来源核对。运行 `python skill/report_evidence/check_manifest.py --root . --manifest skill/report_evidence/manifest.json`。不访问硬件。修改题目时由使用者审核后填写新清单。

examguard_review：来源确认、事件类型与证据范围的只读复核流程。用于本工程时保持四工具契约，迁移到其他题目需替换事件表及接口。

各目录readme.md包含适用场景、使用、失效条件、失败观察和验证范围。本包文件名按指南统一为小写，skill.md保留原技能正文。二者都不是PYNQ专用技能。
