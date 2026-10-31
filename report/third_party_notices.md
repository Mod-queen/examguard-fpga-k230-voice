# 第三方来源与发布前处理

本包供比赛工程核查，尚未公开发布。原文件中的版权和许可声明保留；本文件不为第三方资产新授予MIT许可。

AMD/Xilinx：Vivado2018.3、MIG、FIFO、时钟等IP及生成文件，位于src/fpga。使用和再分发依各文件及工具原有条件，不能宣称全部RTL均为自研。

开发板与相机/显示基础工程：ACX750-CH569原有板卡工程及相关模块，文件内来源声明保留。提交包整理只调整路径，正式用户逻辑、约束和验收位流另有来源清单。

嘉楠CanMV与Yahboom示例：PipeLine、AIBase、AI2D、Utils、YbUart和人脸示例等，路径见src/k230/vendor及board/k230/records/vendor_provenance.json。固件镜像未包含。

YOLO训练与模型：沿用既有公开预训练和本项目训练分支，血缘见data/model_records。原始权重、曲线和日志作为核查附件，未以现场少量帧冒充独立测试集；发布时分别核对框架、上游权重和数据来源条件。

Python运行依赖：pyserial；SQLite、Tkinter及HTTP等来自Python标准环境。模型服务、JoyCode账户和网络连接由使用者自行配置，本包无API密钥或平台账户。

2026年10月31日开源时需要确定团队原创部分许可、逐项保留第三方许可，并将不具备再分发依据的资产改为取得方式或重生成步骤，再填写真实仓库地址。
