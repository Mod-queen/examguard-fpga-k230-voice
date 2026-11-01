# 来源与许可范围

license.txt的MIT许可适用于团队原创贡献；不改变上游文件、厂商IP和模型的原版权或许可。保留源文件内全部原声明。

| 类别 | 来源与位置 | 处理 |
| --- | --- | --- |
| FPGA厂商IP | AMD/Xilinx，src/fpga内MIG、FIFO和时钟IP | 保留.xci、配置及原声明，复原使用Vivado2018.3；不是团队自研RTL |
| 板卡基础模块 | ACX750板卡基础工程 | 保留原文件来源声明 |
| CRC | Easics，crc32_d8.v | 原文允许保留版权声明后使用和分发，声明未删 |
| K230示例 | CanMV与Yahboom，src/k230/vendor | 保留原文件；来源与改动见board/k230/records/vendor_provenance.json |
| 目标模型 | YOLOv8及本项目训练记录 | 训练/上游来源和SHA见data/model_records；上游权重和框架遵循其原许可，不套MIT |
| PC依赖 | Python标准库、pyserial | 依赖版本和取得方式见requirements.txt与复原说明 |

不包含厂商固件镜像、Vivado安装包、个人face_db、API密钥、网页密码或真实采集数据库。硬件与软件原许可条件独立保留。

训练数据来源与使用范围见[data/recognition.md](data/recognition.md)。COCO与Open Images遵循原始数据许可；自采素材只展示本项目已提供的目标裁图及书籍识别图。
