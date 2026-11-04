# iOS 原生播放链路：架构与实际验收状态

本文记录本轮 iOS 4K/HDR 播放修复的实际实现与已取得的证据。未验证的项目明确标为“未验证”，不把代码完成、模拟器通过或单测通过写成真机验收。

## 1. 结构

```
业务层            PlPlayerController（门面，保留原 API 与调用方）
                     ├── PlaybackSession   唯一活动后端 + 意图（play/pause/seek/rate）
                     ├── PlaybackSnapshot  唯一状态源（Duration 为单位）
                     └── PlaybackSnapshot → Rx（position/duration/buffered 由同一对象派生）

后端              mpv backend（media_kit，SDR 与既有场景）
                  native backend（AVPlayer + AVPlayerLayer，iOS HDR）

媒体             HlsBridge（本机 loopback HLS + 字节范围转发）
                  DashIndex（sidx 解析）/ Mp4BoxPatcher（stsd 结构化修补）
```

关键规则：

- 同一会话只有一个后端。切源时旧后端先 dispose，再开新源；不存在“两个都开着、只隐藏/静音其中一个”。
- `positionInMilliseconds` 与 `position` 来自同一个 snapshot，不存在两个时间源。
- 事件带 generation，过期事件被丢弃。
- 原生会话由控制器持有，平台视图只 attach；旋转、全屏、控制条显隐不会重建会话。

## 2. 媒体适配（阶段 2）

服务返回的 HDR/4K rendition 是分离的 DASH fMP4 轨道，`SegmentBase` 直接给出初始化段与索引范围（实测示例：视频 `0-999` / `1000-1259`，音频 `0-933` / `934-1205`）。

采用方案 B：本机按需 HLS 桥接。

- 只提供清单与按需字节范围转发，不预先下载全片，不写临时整片文件。
- 清单条目数与 `sidx` 引用数一致（实测 19 段短视频、1726 段 8575 秒长片）。
- 分片偏移按 `indexRange.lowerBound + sidx.boxEnd + first_offset + 前序长度` 计算；把 `boxEnd` 当绝对位置会让首片落在文件头。
- `sidx` 字段按 ISO/IEC 14496-12 读取：`reference_type|referenced_size`、`subsegment_duration`、`starts_with_SAP`。按错误顺序读出的“长度”看似合理但偏移全错。
- 仅对 loopback 监听，路径含不可猜 token，未授权路径返回 404，不作为通用代理。
- 只放行 ATS 的 localhost/127.0.0.1 例外，未开启全局不安全加载。

## 3. 已实测证据

在本机（macOS，AVFoundation 同一实现）与 iOS 模拟器上取得：

| 项目 | 结果 | 说明 |
| --- | --- | --- |
| `sidx` 解析（真实 CDN 字节） | 通过 | 视频 19 段/97.3s、音频 20 段、长片 1726 段/8574.76s |
| 分片字节与上游一致 | 通过 | 首片、中间片、末片与上游 Range 结果逐字节相同 |
| 清单被 AVFoundation 接受 | 通过 | `AVURLAsset.playable=true`，时长 97.3s |
| 单 item 双轨 | 通过 | `AVPlayerItem` ready，tracks=2（video+soun） |
| 模拟器实际播放 | 通过 | 4K/HDR 样片在模拟器中出画（截图非全黑、非绿屏） |
| 结构化 `hev1`→`hvc1` | 通过（无 HEVC 源时为空操作） | `mdat` 字节不变，非 HEVC 轨道不改动 |
| 全量单测 | 285 通过 | `flutter test` 退出码 0 |
| Swift 解析/清单测试 | 18 通过 | `tool/swift_parser_tests.sh` 退出码 0 |

## 4. 未能证明的部分

- **真机 HDR 呈现**：模拟器没有 HDR 显示模式，因此本轮只验证到“原生链路能解码并出画”。真实 PQ/HLG 合成、亮度与色域需要在支持的 iPhone 上验证；缺少设备时不得据此宣称 HDR 成功。
- **音画同步毫秒级偏差**：未取得可解释的声画测量，只验证了单 item 共享时钟的架构事实。
- **30 分钟连续播放与热状态**：未测。
- **Dolby Vision / AV1 HDR**：未单独验证；`hev1`→`hvc1` 修补只针对 HEVC 路径，Dolby Vision 不做改动。
- **AirPlay / PiP 跨后端**：原生 PiP 未实现，iOS PiP 仍只服务 mpv 纹理路径，且已在原生路径上显式禁用而非静默失效。

## 5. 能力门禁

`HdrSupport.canPresentHdr()` 查询 `AVPlayer.availableHDRModes`。返回 0 时（模拟器、HDR 关闭的设备）不把 10-bit rendition 路由到原生层：否则 AVFoundation 会把唯一的 PQ 变体全部过滤，item 永远不 ready，表现为黑屏。此时回落到 8K/最高 SDR 档，并在质量选择中保持既有可见性语义。
