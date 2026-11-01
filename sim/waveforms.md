# 模块波形展示

主展示采用Vivado原生窗口截图，图像、WDB数据库和用例逐项对应。完整导航见[模块仿真表](readme.md)。

| 展示内容 | 自检用例 | 原生截图 |
| --- | --- | --- |
| 摄像头配置完成 | camera_init_contract_tb | [查看](images/native_selected/01_camera_finished_clean/vivado_wave.png) |
| 摄像头应答失败与重试 | camera_init_contract_tb | [查看](images/native_selected/02_camera_retry_clean/vivado_wave.png) |
| DVP像素采样 | dvp_capture_contract_tb | [查看](images/native_selected/03_dvp_pixel_final/vivado_wave.png) |
| RGMII双边沿数据 | gmii_rgmii_contract_tb | [查看](images/native_selected/04_ethernet_edges_03/vivado_wave.png) |
| 请求队列满与顺序保持 | event_request_fifo_optimized_tb | [查看](images/native_selected/05_fifo_full_clean/vivado_wave.png) |
| DDR写响应 | history_store_axi_tb | [查看](images/native_selected/06_ddr_write_clean/vivado_wave.png) |
| 考试阶段切换 | exam_fsm_tb | [查看](images/native_selected/07_exam_stages_clean/vivado_wave.png) |
| 证据排队与结果返回 | ddr_evidence_queued_tb | [查看](images/native_selected/08_evidence_result_clean/vivado_wave.png) |

每张原生图的SHA256与WDB位置见[截图索引](images/native_selected/index.json)。

各模块页另提供VCD仿真波形导出图，便于直接阅读信号变化；其来源批次见[test_matrix.tsv](test_matrix.tsv)。原生截图与VCD导出都属于仿真结果，现场记录单列于[board](../board/verification/readme.md)。

当前验证结果按源码哈希关联；163个不同自检用例、模块关联数量和截图数量是不同口径。每个模块页均列出实际用例、日志与机器可读结果，没有用截图数量替代自动判据。
