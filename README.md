# 漫剧 Duo 0.1.0

独立的 iPhone 和 iPad 漫剧客户端。支持发现、搜索、链接导入、选集、原生播放、倍速、自动下一集、追剧和续播。窄屏在视频下方显示选集，宽屏把选集放在右侧。当前集优先准备，下一集可自动预取，缓存上限约 1 GB。

打开 ManjuDuo.xcodeproj，选择 ManjuDuo scheme。可直接在模拟器运行。安装到 iPhone 或 iPad 时，在 Signing & Capabilities 选择自己的 Team，然后选择设备并运行。部署目标为 iOS 17。

使用 scripts/check.sh 运行协议、数据解析、本地存储和媒体格式测试。项目使用 GPL-3.0-only，第三方署名见 ManjuDuo/Vendor。

首次播放需要下载并准备当前集。可用性取决于内容来源与网络。首版支持分集缓存和本机观看历史。
