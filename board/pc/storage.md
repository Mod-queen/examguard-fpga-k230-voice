# 证据统一保存

本次使用者确认的根目录：`D:/fpga_real/证据回溯`。

```text
证据回溯/
├── sessions/       SQLite事件与状态存档
└── evidence_out/   EG像素、图像、HR结果及校验manifest
```

在`src/pc/host/launch_config.json`中修改`storage_root`可配置其他位置。绝对路径直接使用；相对路径以host目录为基准；省略则沿用host下默认位置。接收服务与桌面均读取同一配置，Agent和JoyCode沿用桌面当前选择。

更换保存位置前正常退出监考台，完整复制已有sessions和evidence_out并核对后再启动。不要只更改回放选择而保留接收端旧路径。已有证据及个人资料不进入公开仓库和工程RAR。
