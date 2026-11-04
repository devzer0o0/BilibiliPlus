# iOS 原生播放链路：架构与实际验收状态

本文记录本轮 iOS 4K/HDR 播放修复的实际实现与已取得的证据。未验证的项目明确标为“未验证”或 BLOCKED，不把代码完成、模拟器通过或单测通过写成真机验收。

## 1. 结构

```
业务层            PlPlayerController（门面，保留原 API 与调用方）
                     ├── SourceGenerationAllocator  唯一的媒体代次分配者
                     ├── PlaybackSession    唯一活动后端 + 意图（play/pause/seek/rate）
                     ├── NativeSessionHost  原生会话与门面之间的生产接线
                     ├── PlaybackSnapshot   唯一状态源（Duration 为单位）
                     └── PlaybackRoute      none / preparing / mpv / native / disposed

后端              mpv backend（media_kit，SDR 与既有场景）
                  native backend（AVPlayer + AVPlayerLayer，iOS HDR）

媒体              HlsBridge（本机 loopback HLS + 字节范围转发）
                  DashIndex（sidx 解析）/ Mp4BoxPatcher（stsd 结构化修补）

定制功能          NativePipCoordinator（原生 PiP）
                  NativeFrameCapture（AVPlayerItemVideoOutput 取帧）
                  听视频 = audioOnly presentation（同一条 AVPlayer）
```

关键规则：

- 同一会话只有一个后端。切源时旧后端先 dispose，再开新源；不存在“两个都开着、只隐藏/静音其中一个”。
- `positionInMilliseconds` 与 `position` 来自同一个 snapshot，不存在两个时间源。
- **媒体代次只由门面分配一次**：`SourceGenerationAllocator.beginSourceChange()` 在 `setDataSource` 的切换事务开始时调用，会话与后端原样接收，任何下游都不再自增。
- 四个身份分开：`sourceKey`（素材身份）、`sessionId`（后端会话）、`generation`（媒体代次）、`viewId`（平台视图）。旋转、全屏、控制条显隐不产生新的媒体代次。
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
- 上游任务按会话追踪：`stop()` 取消全部 dataTask，迟到回调不再写入已关闭连接。
- `BANDWIDTH` 不再恒为 1；服务未给带宽时由 `sidx` 的字节数/时长计算，避免播放器把整条轨道当成免费。

## 3. 本轮修复（阶段 A/B/C/E/F）

| 问题 | 处理 | 证据级别 |
| --- | --- | --- |
| generation 三处各自自增，首次原生事件被过滤 | 门面唯一分配；`NativeSessionHost` 严格按自身代次转发 | 自动化通过（真实门面→会话→后端替身） |
| 能力判断缺失导致强制解包 | `PlaybackRoute` + `PlaybackCapabilities`，所有入口统一拒绝路径 | 自动化通过 |
| `setShader` 先写状态后发命令 | 先查能力，命令成功后才更新选择与持久化；原生路径不清除 mpv 偏好 | 自动化通过 + 静态审阅 |
| 听视频直接操作 mpv | `setAudioOnly` 单一入口；原生走 audioOnly presentation | 编译通过 + 单测（未见真机） |
| 截图无能力门禁、异常不清理 | `try/finally`、`ui.Image` 必然释放、按后端给准确原因 | 自动化通过 |
| 原生截图缺失 | `AVPlayerItemVideoOutput` 取帧 → sRGB PNG，带帧时间/尺寸/色彩空间/toneMap 标记 | 编译通过（未真机验证） |
| 亮屏与后台策略分散 | `_syncWakeLock` + `handleAppLifecycle` 统一两种后端 | 自动化通过（策略）+ 未真机 |
| `resumeIfStalled` 覆盖系统暂停 | 只在 `reasonForWaitingToPlay` 存在时恢复；PiP/中断置 `interrupted` | 代码审阅 + 编译通过 |
| 视图注册表强引用 | 弱引用 + 显式 `unregister` + deinit；仅移除自己持有的 layer | Swift 测试 18 项通过 |
| `fetchIndex` 同步信号量阻塞 | 全异步 + 代次校验 + 任务取消 | 编译通过 |
| 切画质时原生参数未同步 | `buildPlaybackRequest` 单一构造入口，`updatePlayer` 重建原生描述 | 自动化通过 |
| 回退静默 | `SelectedRendition` + `RenditionFallback`，同分辨率优先，一次提示 | 自动化通过 |
| HDR 类型靠 codec 名推断 | 只读媒体元数据；缺失即 unknown；PQ/HLG/DV 分开 | 自动化通过 |
| 原生 PiP 缺失 | `AVPictureInPictureController` 基于同一条 layer | 自动化通过（协调器）+ 编译通过 |
| AirPlay 视频被默认尝试 | `allowsExternalPlayback = false` + 能力说明 | 编译通过 |

## 4. 已实测证据

| 项目 | 结果 | 说明 |
| --- | --- | --- |
| `sidx` 解析（真实 CDN 字节） | 通过 | 视频 19 段/97.3s、音频 20 段、长片 1726 段/8574.76s |
| 分片字节与上游一致 | 通过 | 首片、中间片、末片与上游 Range 结果逐字节相同 |
| 清单被 AVFoundation 接受 | 通过 | `AVURLAsset.playable=true`，时长 97.3s |
| 单 item 双轨 | 通过 | `AVPlayerItem` ready，tracks=2（video+soun） |
| 结构化 `hev1`→`hvc1` | 通过（无 HEVC 源时为空操作） | `mdat` 字节不变，非 HEVC 轨道不改动 |
| Swift 解析/清单测试 | 18 通过 | `tool/swift_parser_tests.sh` |
| Flutter 全量单测 | 333 通过 | 本轮末次 `flutter test` |
| Release 编译（无签名） | 通过 | `flutter build ios --release --no-codesign` |
| Release 诊断隔离 | 通过 | `PILIPLUS_HLS_TRACE` / `PILIPLUS_HDR_TRACE` 在 Release 产物中不存在 |

## 5. 未能证明的部分（明确未完成）

- **真机 4K 连续播放 / 热状态 / 音画同步**：`tool/device_preflight.sh` 本轮返回
  `STATE=BLOCKED_DEVICE_UNAVAILABLE`（iPhone Air 未连接）。所有真机项目状态为 **NOT RUN**，不是通过。
- **真机 HDR 呈现**：模拟器没有 HDR 显示模式，只验证到“原生链路能解码并出画”。PQ/HLG/DV/AV1 HDR 的屏幕呈现层级无证据。
- **原生截图 / 原生 PiP / 听视频**：代码与单测完成，未经真机或模拟器交互验证。
- **AirPlay 远程视频**：未实现，已显式门禁。
- **签名产物**：需要的 Team ID 未提供，`tool/ios_build.sh` 返回 BLOCKED_SIGNING；本轮的构建产物是**无签名编译检查**，未安装、未运行。

## 6. 能力门禁

`HdrSupport.describeHdrPath()` 查询原生侧 `hdrCapability`：

- `eligibleForHDRPlayback`（iOS 15 部署目标即可用）是“设备能不能播 HDR”的主要答案；
- `availableHDRModes`（iOS 17+）作为补充，不作为唯一答案——否则 iOS 15/16 设备会被误判为不支持；
- 结果带原因并短时缓存（20s），回到前台或显示配置变化后可重新查询。

返回不可用时，不把 10-bit rendition 路由到原生层：否则 AVFoundation 会把唯一的 PQ 变体全部过滤，item 永远不 ready，表现为黑屏。此时保持同分辨率回退到 SDR，并把原因显示在播放信息面板。
