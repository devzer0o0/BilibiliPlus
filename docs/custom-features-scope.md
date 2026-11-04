# 定制功能支持范围（本轮）

按当前 HEAD 的实际能力，逐项说明“能做什么 / 怎么拒绝 / 证据级别”。

| 功能 | mpv 路径 | 原生 AVPlayerLayer 路径 | 证据级别 |
| --- | --- | --- | --- |
| 播放 / 暂停 / seek / 倍速 | 支持 | 支持 | 自动化通过（会话意图） |
| 画中画 | 支持（纹理 PiP，`IOSPipHelper`） | 支持（`AVPictureInPictureController`，同一条 layer） | 协调器单测通过；真机 NOT RUN |
| 听视频 | 支持（`vid=auto/no`） | 支持（audioOnly presentation，无视频变体） | 编译通过 + 单测；真机 NOT RUN |
| 切换音轨 | 支持（mpv 命令） | 不支持（HLS 只有一条音频 rendition） | 能力位拒绝 |
| 静态截图 | 支持（纹理） | 支持（`AVPlayerItemVideoOutput`） | 编译通过 + 能力单测；真机 NOT RUN |
| 动态截图（WebP） | 支持（独立 `MpvConvertWebp` 转码器） | 不支持 | 能力位拒绝 |
| 超分辨率（shader） | 支持 | 不支持 | 自动化通过（拒绝路径） |
| 播放器音量 | 支持（mpv 混音） | 不支持（走系统音量） | 能力位拒绝 |
| 播放信息面板 | 支持（mpv 详细属性） | 支持（媒体/路径/回退原因） | 自动化通过 |
| AirPlay 视频 | 不支持 | 明确不支持（loopback 媒体） | 显式门禁 |
| AirPlay 音频 / 蓝牙音频 | 支持 | 支持（系统音频路由） | 未单独验证 |
| DLNA | 既有功能，未改动 | — | 未回归 |
| 字幕 / 弹幕 / 历史 / 连播 | 既有功能，未改动 | 字幕以叠加层显示 | 既有测试通过 |

## 拒绝语义

所有“不支持”都走同一条路径：`PlaybackCapabilities` + `PlaybackRoute`，返回带原因的中文提示，
而不是静默失败或强制解包。原因区分为：

- 正在准备播放（`preparing`）
- 当前是原生路径（`native`）
- 播放器已释放（`disposed`）
- 尚未开始播放（`none`）

## 尚未验证的部分

原生 PiP、听视频、原生截图三项的代码与单测已完成，但**没有任何真机或模拟器交互证据**。
本轮设备不可用（见 `ios-device-acceptance-2026-11-04.md`），因此这三项状态为未运行。
