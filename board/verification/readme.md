# 当前板级验证

2026-11-01最新质量版已写入FPGA QSPI Flash，完成整片16MiB读回比对。用户执行全断电重上电，随后COM5观察111条ST、health=0、boot108；COM12观察76条递增识别回执，无Traceback。观察在启动后进行。

| 记录 | 来源 |
| --- | --- |
| [Flash读回](quality_flash_readback.json) | 实际写入、Verify及独立逐字节核对，SHA对应当前镜像 |
| [上电后观察](quality_poweron_passive.json) | 两串口只读；写入0字节 |
| [现场复测](quality_field_acceptance.json) | 用户反馈身份、手机/紫书、扭头、连续语音、证据回放及不透光遮挡正常 |
| [K230 SD核对](k230_sd_verified.json) | 当前入口、模型及人脸库核对；清理旧诊断文件，现用程序未替换 |

现场复测是功能反馈；训练指标和布线后资源/时序另见各自记录。旧版Flash与冷启收据保留原时间及范围，当前版本以[版本指针](../current_release.json)为准。
