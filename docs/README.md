# 文档索引

本目录记录 PiliPlus iOS 分支的架构、验证证据与具体改动。

## 本次改动

| 文档 | 内容 |
| --- | --- |
| [应用图标与启动画面](app-icon-and-launch-screen.md) | 图标复刻 bilibili 国际版并换为 DeepSeek 蓝；启动画面替换、底色修正、启动耗时实测 |
| [首页分享给我的视频](home-shared-videos.md) | 指定用户私信分享的取数链路，以及三个真实缺陷（纯文本丢弃、去重顺序、标题为 URL）的定位与修复 |

## 播放与架构

| 文档 | 内容 |
| --- | --- |
| [iOS 原生播放架构](ios-native-playback-architecture.md) | mpv 与 AVPlayer 双后端、单一播放时钟与身份分离 |
| [自定义功能范围](custom-features-scope.md) | PiP、听视频、截图、超分入口、后台与生命周期 |
| [分支验证方法](verifying-this-branch.md) | 如何在本地复现验证 |
| [分支状态](branch-status.md) | 分支整体状态与逐项证据等级 |

## HDR

| 文档 | 内容 |
| --- | --- |
| [HDR 播放证据](ios-hdr-playback-evidence.md) | PQ/HLG/Dolby Vision 识别与显示通路的实测记录 |
| [HDR 可行性](ios-real-hdr-feasibility.md) | 平台能力边界 |
| [HDR 10bit 方案](ios-hdr-10bit-plan.md) | 10-bit 通路设计 |

## 其他

| 文档 | 内容 |
| --- | --- |
| [iOS AV1 适配](ios-av1-adaptation.md) | VideoToolbox ABI 与注入流程 |
| [视频输出尺寸](video-output-size.md) | 分辨率与码率选择 |
| [布局审计](ios-layout-audit.md) | iPhone Air 布局检查 |
| [设备验收](ios-device-acceptance-2026-11-04.md) | 真机验收记录 |
| [第三方许可](third-party-licenses.md) | 依赖许可 |
