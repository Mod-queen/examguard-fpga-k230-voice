# AMD自主选题初级组对应

依据用户提供指南第3.3节（PDF物理22至25页）。主办方补充通知另要求初级组选手开源、系统PDF报告和视频匿名、中英文海报各一页PPTX。

| 要求 | 仓库位置 |
| --- | --- |
| 完整源码与工程 | src/fpga、src/k230、src/pc |
| 仿真和验证结果 | sim/readme.md逐模块展示，sim/results保实际结果 |
| 综合、资源、时序与指标 | build/reports/quality_current、quality_physical、qa/quality |
| 上板、脚本与实测 | board/current_release.json、board/verification；升级候选单列 |
| 可复原构建脚本 | reproduce.cmd、tools/reproduce.ps1、build/build_fpga.tcl |
| 工具版本与环境 | build/reproduction.md，明确Vivado2018.3与原因 |
| 技能、适用、使用及失效 | skill/readme.md及各项skill/readme |
| 优化、协作、自纠错、技能提炼、从零复原 | report现有总报告附录及配套记录；Word修订按用户要求暂停 |
| 英文小写目录及文件 | 当前全部跟踪路径核对；中文用于正文 |
| 开源许可 | license.txt及third_party_notices.md，原许可保留 |

系统上传代码与GitHub是两个交付物：代码用RAR、200MB以内，含源码和bit；技术文档另交PDF、50MB以内；视频按后台截图为MP4/AVC H.264、3分钟内、300MB以内。后台海报字段标选填，但AMD补充通知要求本赛道提交两页PPTX，按通知执行。
