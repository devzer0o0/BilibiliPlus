# PiliPlus iOS 4K / HDR 播放修复：完整执行提示词

基于 2026-11-04 的只读审计；基线提交为 b9e66062974b153bd03a72e37b53b53f497f2b76。本文交付的是实施提示词，不表示其中的修复、性能指标或真机验收已经完成。

## 使用方法

将“提示词开始”至“提示词结束”的全文交给能够读取此仓库、修改代码并运行测试的编码代理。建议作为一项分阶段任务执行，不要把后面的阶段脱离总约束单独执行。若用于新会话，先让代理复核工作目录、当前提交和用户变更；不要假定行号或历史测试结果仍然有效。

---

# 提示词开始

你是一名负责 Flutter、iOS AVFoundation、libmpv 和流媒体封装的高级工程师。请在当前 PiliPlus 仓库实施以下修复，而不是再次只给建议。先阅读现有实现、补回归测试，再逐阶段修改和验证。用户不希望反复操作电脑；在现有权限内自行完成可自动化的工作，但不得绕过权限、锁屏、签名或系统安全限制。

## 一、最终目标与不可变约束

### 最终目标

修复用户反馈的 4K 卡顿、HDR 音画不同步、HDR 进度条无法呼出，并一并修复支撑这些功能的后端隔离、时间单位、持续状态更新、长视频、字幕、切流和生命周期问题。真正 HDR 指 HDR 源经过适合 HDR 的原生显示链路，不是把 HDR 转成 SDR 后仅保留标签。最终交付应是同一份源码对应的可验证构建产物，而不是“代码改过”或“单测通过”就结束。

### 硬约束

1. 工作目录预期为 /Users/space/IdeaProjects/会话/PiliPlus；先用 pwd 和 git status 确认。基线分支为 feature/4k-output-size，实际状态不一致时以现场读取为准。保留用户已有改动，不重置、不清理无关文件、不擅自换分支。
2. 行为变更限定为 iOS 播放修复。允许抽取共享接口，但必须保留 Android、macOS、Windows、Linux 的既有行为；不要全平台修改硬解策略。不要升级 Flutter、media_kit、FFmpeg 或替换播放器依赖来绕过问题，除非确实必要且取得相应授权。
3. Bundle ID 必须保持 com.example.pilipalax。保留既有 AV1 VideoToolbox 适配及设备侧 Avcodec 二进制；ABI 61.3.100、359 个导出符号的约束不变。不同平台/架构产物不能混用。记录原二进制校验信息，不能只看导出数量便认定实现完全未变。
4. 保留真实 4K 源的选择能力，不能以偷偷改选 1080P、降帧率或转 SDR 掩盖问题。输出表面按实际显示尺寸缩放与降低源画质是两回事；若调整表面尺寸，必须保留源分辨率、缩放/裁剪及截图相关语义。
5. SDR 保留 mpv 路径；原生 HDR 优先保留 AVPlayerLayer，不开展没有必要的自研渲染器重写。不要声称 AVPlayerLayer 是整个 iOS 唯一的 HDR 公开实现途径。
6. 不能把所有 10-bit 视频都当成 HDR；要区分位深、传递函数、色域、HDR10/HLG/Dolby Vision 和编码支持情况。AV1、HEVC、HDR10、HLG、Dolby Vision 必须分别验证，不得互相替代验收。
7. 不读取或输出不必要的 Cookie、Token、签名密钥、完整带鉴权参数的媒体 URL；不提交凭证、个人媒体、临时诊断文件或下载的视频片段。日志中的资源以脱敏标识关联。
8. 现有首页需求不能回退：StepGo UID 3546605619776050；已打开的分享消失；分享区不占用六条推荐名额。本任务不改写该业务，只执行其已有回归。
9. 模拟器优先完成编译、控制交互、切流、状态机和测试；真机负责硬件解码、HDR 输出、音画同步、持续性能与热状态验收。不得用模拟器性能推断真机性能。
10. 不擅自 push、修改签名身份或占用用户正在使用的设备。没有可用权限/解锁设备时继续独立工作，明确记录剩余验收，不得虚报通过。最后报告使用中文、简洁，证据完整；没有取得所有必要证据不得宣称全部完成。

## 二、必须先复核的事实与证据位置

以下是当前代码的审计事实，不是运行时测试结果。先复核；若代码已变，更新证据，而不是机械照搬行号。

| 问题 | 当前证据 | 必须纠正的误判 |
| --- | --- | --- |
| HDR 未排除 mpv | [视频初始化](<lib/pages/video/controller.dart#L753-L794>)、[HDR 路由](<lib/pages/video/controller.dart#L1012-L1035>)、[mpv 打开与自动播放](<lib/plugin/pl_player/controller.dart#L919-L1003>)、[双发 play](<lib/plugin/pl_player/controller.dart#L1263-L1279>) | 确认的是两条打开/播放路径和音轨配置共存；不能未经实测就断言实际双声或认定它是所有卡顿的唯一原因。 |
| 时间单位与状态源冲突 | [秒契约](<lib/plugin/pl_player/controller.dart#L91-L108>)、[mpv 事件](<lib/plugin/pl_player/controller.dart#L1042-L1123>)、[原生回写](<lib/pages/video/view.dart#L1247-L1265>) | 原生秒数乘 1000 写进秒字段；但当前原生字幕也按毫秒消费，修一端会影响另一端，必须一起改。 |
| 原生更新仅约 80 秒 | [轮询](<lib/plugin/pl_player/widgets/hdr_video_surface.dart#L150-L168>) | 40 次轮询结束表示原生状态通路停止更新，不等于 AVPlayer 必然停播。 |
| HDR 缺少完整控件和手势 | [HDR Stack 与分支](<lib/pages/video/view.dart#L1239-L1355>)、[正常底控](<lib/plugin/pl_player/view/view.dart#L1610-L1627>) | hitTest 返回 nil 不会生成根本没有挂载的进度条，也不构成交互已通过的证据。 |
| 普通播放器 UI 依赖 mpv 实例 | [PLVideoPlayer 初始化](<lib/plugin/pl_player/view/view.dart#L250-L352>) | 不能只停止/不创建 mpv 后直接套用原组件，其中有强制解包及生命周期直调。 |
| 倍速和 seek 只部分桥接 | [控制方法](<lib/plugin/pl_player/controller.dart#L1204-L1279>)、[原生通道](<ios/Runner/HdrVideoPlugin.swift#L64-L77>) | seekTo 已有镜像，不应报成全部无法 seek；底层 seek、初始续播、倍速仍需统一。 |
| 切画质/编码/音质更新不统一 | [updatePlayer](<lib/pages/video/controller.dart#L715-L737>)、[固定 key](<lib/pages/video/view.dart#L1267-L1275>)、[创建参数](<lib/plugin/pl_player/widgets/hdr_video_surface.dart#L185-L205>) | updatePlayer 绕过原生路由重算；平台视图 creationParams 不会自动重载。queryVideoUrl 已有清空逻辑，不能断言所有分 P 都必然残留。 |
| 双播放器和无条件自动播放 | [原生播放器](<ios/Runner/HdrVideoPlugin.swift#L82-L221>)、[原生音频](<ios/Runner/HdrVideoPlugin.swift#L306-L338>) | 每秒追赶不是共享音视频时钟；准备期间 pause/autoplay=false 可能被完成回调中的 play 覆盖。 |
| 片段截断和索引不完整 | [装配器](<ios/Runner/DashAssembler.swift#L15-L189>) | maxFragments=19 仍存在；短视频恰好含 19 段不能证明长视频正常。现有解析不足以生成可信的时间索引。 |
| 容器全局字节替换 | [asHvc1](<ios/Runner/HdrVideoPlugin.swift#L268-L305>) | 不能对整份文件搜索替换 hev1，也不能把所有 Apple 平台对 hev1 的支持描述为绝对不可能。 |
| 字幕协议及缓存不一致 | [字幕接口](<lib/http/video.dart#L912-L927>)、[原生调用](<lib/pages/video/controller.dart#L1096-L1108>)、[字幕消费](<lib/pages/video/widgets/native_subtitle_overlay.dart#L1-L113>)、[Future 缓存](<lib/pages/video/view.dart#L1295-L1314>) | getSubtitles 默认返回 VTT；JSON 格式分支当前抛 UnimplementedError，不能仅补一个 format 参数就当解决。 |
| 硬解设置与实际解码混淆 | [硬解默认值](<lib/plugin/pl_player/models/hwdec_type.dart#L45-L64>)、[偏好处理](<lib/utils/storage_pref.dart#L272-L289>)、[初始化选项](<lib/plugin/pl_player/controller.dart#L850-L889>) | videotoolbox 是请求策略，不等于永不软回退；旧值是读时归一化，不是已持久化迁移；该配置也不控制 AVPlayer。 |
| HDR 能力判定矛盾 | [HDR 能力](<lib/plugin/pl_player/utils/hdr_support.dart#L18-L61>)、[位深检测](<lib/utils/video_utils.dart#L198-L227>) | Platform.isIOS、位深、EDR 请求和当前真正显示 HDR 不能混成一个布尔值。 |
| 发布和文档证据不足 | [原生日志](<ios/Runner/HdrVideoPlugin.swift#L246-L265>)、[发布检查](<tool/verify_release_constraints.sh>)、[总回归脚本](<tool/full_regression.sh>)、[HDR 可行性文档](<docs/ios-real-hdr-feasibility.md>) | 单测通过、元数据正确、源码干净、截图正常，都不能分别替代交互、完整播放、产物纯净性和可见 HDR 验收。 |

## 三、总体架构结论

采用“一个业务控制门面 + 一个当前活动后端 + 一个统一状态源 + 可替换的视频表面”。

- PlPlayerController 继续作为业务/UI 的兼容门面，避免一开始大规模重写所有调用方。
- mpv adapter 服务现有 SDR 及已支持场景；native adapter 服务通过能力和资源验证的 iOS HDR 场景。
- 同一播放会话只能有一个活动后端发布状态、输出音频并承担播放。不要用仅隐藏 mpv 画面或仅静音 mpv 代替排他性修复。
- Flutter 的弹幕、字幕、顶部/底部控制和手势是可复用的覆盖层，不绑定 mpv 的 VideoController。
- 原生目标是一个 AVPlayer/AVPlayerItem 负责音视频的共同时间轴。一个 item 可以由 HLS 主清单引用独立的视频清单与音频组，不必先合成一个巨大的音视频文件。
- DASH 资源适配单独做可行性门槛。优先使用服务实际提供且验证可播的合法原生资源；否则验证本机 DASH/fMP4 到 HLS 的按需桥接。不得虚构服务端 HLS 地址，也不得只把后缀改成 m3u8。
- 双 AVPlayer 的纠偏只能作为暂时过渡，不是最终同步方案。不要继续调大定时器频率来替代流媒体和时钟架构修复。

按以下阶段执行；各阶段先定义测试与完成条件，再改实现。后端接口设计与媒体适配 PoC 可以并行研究，但共享文件修改必须协调，集成前统一契约。

## 阶段 0：建立基线与复现矩阵

1. 读取项目约束、实际 Flutter/Dart、Xcode/SDK、iOS 部署版本、依赖锁定和当前修改。历史 Flutter 路径为 /Users/space/development/fl-3479/flutter/bin/flutter；先确认存在并核对版本。不要自动升级环境。
2. 读取相关现有测试和验证脚本，确认它们真正覆盖什么、会操作哪个设备、检查哪个构建产物。先审脚本再运行，不能把可能安装/拉起真机 App 的脚本当成纯测试。
3. 创建证据矩阵：问题、素材/分 P、实际清晰度/编码/帧率/HDR 类型、活动后端、复现步骤、观测值、预期值、当前状态、对应测试。
4. 同时记录源码提交、构建模式、设备型号/系统/屏幕状态、网络条件、采样窗口；不要根据设备营销名称猜芯片。
5. 先运行可执行的基线静态检查和单测，记录真实退出码与新旧失败差异。历史 248 个通过不是本轮结果。新增测试应覆盖已确认缺陷，不能只造脱离生产输入的字符串。
6. 4K SDR 与原生 HDR 分开建样本，不能把隐藏 mpv 的性能数据当成当前原生画面的数据。临时观测工具限定 debug/profile 或显式诊断构建，不提交敏感 URL。

完成条件：可追踪的基线、问题矩阵及每个阶段的测试入口；不能在没有基线的情况下开始大范围参数试错。

## 阶段 1：统一后端、时间与会话状态

### 1.1 最小接口，而非泛化框架

允许新增轻量 PlaybackBackend、PlaybackSource、PlaybackSnapshot/Event、BackendCapabilities 等类型；名字可以遵循现有规范，但语义必须清楚：

- PlaybackSource 是不可变的完整源描述，至少包括业务媒体/分 P 标识、representation/编码/动态范围、视频与音轨、备用 URL、受控请求头、初始化/索引范围及网络/本地/live 类型；初始位置、自动播放意图、倍速、音量/静音另以 PlaybackRequest 表达，避免用户暂停也被识别为换源。凭证只能在必要的受控边界传递。
- 后端接口覆盖 prepare/open、play、pause、seek、setRate、必要的音量/静音/音轨能力、事件订阅、dispose；不要在所有平台假定相同能力。
- 内部统一用 Duration 或明确单位的类型。现有 position、duration、buffered 若继续按整数秒提供给 UI，就由单一转换层转换；positionInMilliseconds 和 durationInMilliseconds 必须由同一快照派生，不再偷读 mpv。
- 未知/无穷时长、未准备好、缓冲、暂停、播放、结束、失败分别表达。不要将 rate>0 当成完整播放状态。
- 切换源要有独立的 sessionId/sourceGeneration；一次 seek 可另有命令序号。viewId、视频 ID、sessionId 不能混用。事件必须包含所属 generation，过期事件丢弃。

### 1.2 排他性与切换事务

切换时保存统一状态中的位置/播放意图/倍速，隔离旧事件，停止并释放或完全停用旧后端的音频、解码、网络与监听，再准备新源。不要让两条链路同时开始播放以“提高切换速度”。

原生准备不能依赖 mpv open 完成后才设置的 videoState/onInit。解开这一依赖，避免“不创建 mpv”后 HDR 永远无法显示的死锁。可以让原生会话先存在再绑定表面，也可以让表面创建触发 prepare；必须说明所有权，不能让 rebuild 决定业务会话生命周期。

把 queryVideoUrl、updatePlayer、切清晰度、编码、音质、分 P、下一集、重试统一接入 source 更新入口。忙碌标记不能直接 return 而静默丢掉最新切流请求，应明确串行队列或 last-request-wins 规则。注意 queryVideoUrl 目前有清空行为，问题不在于所有入口完全没清理，而是语义不一致、异步结果没有统一失效规则。

原生采用明确 replaceSource 或受控的 source-key 重建，不依赖 UiKitView creationParams 自动变化。旋转、全屏、布局或控制栏显示不能被误识别为新媒体，不能重复下载或从头播放。

### 1.3 通用调用方迁移清单

检索 Player/VideoController 强制解包、state.position、stream.position/playing/buffer、原生 command 与纹理 ID 的调用方；把它们分类为通用业务或 mpv 专属能力。通用业务改用 facade/快照；mpv 专属的 shader、截图/WebP、播放器增益、音轨命令等改为显式能力门禁或提供原生实现，不能 null 吞掉后假装成功。

重点覆盖播放按钮、键盘/焦点、SponsorBlock、字幕/弹幕跳转、评论跳转、分享附带时间、弹幕发送、播放历史、心跳、媒体中心、完成/连播。共享控制器的音频/live/本地视频调用方默认保留原 mpv 适配，不把本次 HDR 改造扩大成全应用迁移。为 BackendFactory、native bridge、PiP bridge 和业务副作用注入 fake，以不创建真实 mpv 的方式测试。

### 1.4 统一事件分发

将 mpv 监听和原生事件都接到同一状态归约/分发入口，活动后端之外的事件不能更新 UI 或业务。覆盖 position/status listeners、播放历史/心跳、弹幕时钟、媒体通知/远程命令、wakelock、缓冲、完成/连播、错误和时长。

原生用生命周期持续的事件订阅，优先 EventChannel/原生观察者，而不是 40 次 describe。进度可在约 200–500ms 合理采样，非播放状态与缓冲/完成/错误等变化立即通知；必要时节流 UI，不能截断生命周期。

### 阶段测试

使用 fake backends 验证：原生激活时 mpv 不 open/play；SDR 不启动原生；旧 generation 事件无效；10 秒只显示 10 秒且毫秒 getter 为 10000；未知时长/结束/缓冲转换正确；自动播放关闭时始终不偷播；准备中暂停后 ready 不自动恢复；快速切源与快速 seek 的最后意图生效；长于 80 秒仍有状态；history/danmaku/completed listeners 各收到正确且不重复的事件。

## 阶段 2：实现可持续、可寻址、单时钟的原生 HDR 资源

### 2.1 先做媒体适配 PoC，设置硬门槛

优先级如下：

A. 如果现有合法播放响应确实提供兼容的完整 MP4/HLS 等 AVFoundation 资源，验证其清晰度、音轨、seek 和 HDR 后使用，不假设存在未返回的接口。

B. 对当前分离的 DASH fMP4，优先 PoC 本机按需 HLS 桥接：HLS 主清单 + video media playlist + EXT-X-MEDIA 音频组；各轨道拥有正确初始化段和片段索引，由一个 AVPlayerItem 播放。原始 fMP4 满足 HLS/AVFoundation 约束时复用字节，不要求一律转码或先重封装全片。

C. AVMutableComposition 或自定义 AVAssetResourceLoader 仅在真实素材证明可流式、可随机 seek、可取消后作为备选。ResourceLoader 管资源请求，不会自动理解 DASH、合并音视频轨道或修复时间戳。不能用它的 API 名称替代容器方案。

可用小型并行 PoC 比较 B 与 C：若 composition/受支持资源加载方案满足同等流式、完整时长和随机 seek 门槛且成本更低，应优先较小方案。输出一次选型记录并选择一条生产主路径，不把多个未验证方案全部留在生产代码里。

PoC 至少覆盖一个 HDR10/HEVC 分离音视频样本、超过 19 个片段的长样本、临近片尾 seek、音频存在且同步、首帧不等待全片下载、退出后无持续下载/播放。验证失败就记录具体不兼容字段和错误，不要一边失败一边把质量入口标成已支持。

### 2.2 正确解析 ISO BMFF / 分片索引

优先使用服务响应已经提供的初始化/索引范围：[BaseItem.segmentBase 与媒体属性](<lib/models/video/play/url.dart#L249-L294>) 已保留这些字段。将其验证并纳入原生 payload，不继续只传两个 URL 后猜测首段范围；缺失时才按有界探测解析。

用有边界检查的结构化解析，不逐字节盲搜 box 类型。至少处理或显式拒绝：32/64 位 box 长度、截断/非法长度、sidx v0/v1、timescale、earliest_presentation_time、first_offset、reference_type、referenced_size、subsegment_duration、SAP。遇到层级索引要递归解析或给明确不支持，不能当媒体字节。

绝对片段偏移以实际 box 位置、sidx end、first_offset 和前序段长度计算；不能把 sidxEnd 当成全部素材的首片段位置。不要假定完整 moov/sidx 永远位于首个 256KiB；按需补读元数据。

视频和音频分别建时间索引，保持 timescale、tfdt/trun、edit list/呈现起点和 track 映射的一致性，不能各自粗暴从零平移而产生固定偏移。随机 seek 从可解码的随机接入点开始，不假设任意片段必是关键帧起点。核对音频 priming/encoder delay；若重排容器字节，必须重新计算适用的 tfhd base-data-offset、trun data_offset 等依赖位置的字段，不是把原头和原片段拼起来就结束。

如果生成 HLS，正确输出 EXT-X-MAP、各片段 EXTINF、TARGETDURATION、VOD/ENDLIST、可选 BYTERANGE、CODECS、RESOLUTION、FRAME-RATE、VIDEO-RANGE 和音频组等适用信息。只有确认 SAP/独立解码条件时才声称独立片段；规范版本和具体标签依据所选封装校验。

### 2.3 HTTP、缓存与资源边界

Range 请求验证状态、Content-Range 起止/总长、实际长度、identity 内容编码和资源一致性。通过 ETag/Last-Modified 或明确版本机制避免跨 CDN/重试时混入不同资源版本。服务器忽略 Range 返回 200 时，只有实现了安全且有界的处理才接收，否则明确失败；不得将整文件当一个片段悄悄追加。处理 416、超时、截断、重定向、签名 URL 到期、有限重试及取消。

网络会话、任务、缓存和临时文件属于明确 session。设置可配置但有界的预取窗口、并发、内存和磁盘预算；长视频时资源占用不能与全片大小线性增长。不用一个不断增长的 Data 保存全片，不用把 maxFragments 改成更大的常数来假装流式。

若采用本机 HTTP bridge，仅绑定 loopback/随机端口，使用不可猜的会话路由，限定允许的上游资源，禁止任意代理和路径穿越；不对局域网开放，不将 Cookie/签名 URL 暴露给通用路由或日志。ATS 与后台行为采用最小必要设置，不为方便开启全局不安全网络。记录新依赖、许可证和维护成本，优先现有能力。手机 loopback 地址不能天然被 AirPlay 接收端访问；远程播放、PiP 与后台代理存活必须单独验证并作能力门禁，不能把本机前台成功当作这些能力也已成功。

### 2.4 安全封装与真实 HDR

禁止全文件替换 hev1。仅在完整校验 stsd/sample-entry、hvcC、VPS/SPS/PPS 以及样本内参数集符合目标格式后，进行结构化修补/必要的无损重封装。保持其他 box、mdat、时基、HDR 静态/动态元数据和位深不受损；写测试证明 mdat 未被意外修改。

不要把 hvc1 改名当成对所有 HEVC 的通用转换；HDR10、HLG、Dolby Vision 各自按规范处理，不能任意改 Dolby Vision 标识。遇到无法保真的源，报告不支持并提供用户明确选择的替代，不伪装 HDR 或绕过 DRM。

检查真实 OS/设备/资源能力。按当前 SDK 使用正确的动态范围 API 和 availability；不要认为设置一个 EDR 布尔值就证明显示为 HDR，也不要为了消除废弃警告擅自抬高最低系统版本。AV1 HDR 原生支持未证实时，不能因为保留了 mpv 的 AV1 库就宣称原生也支持。

### 2.5 单 AVPlayer 状态和同步

一个 item 中的音视频共享系统播放时钟。维护 desiredPlaying、desiredRate、pendingSeek；ready 后先应用初始/最新 seek 和倍速，再根据最后播放意图决定是否播放。保留当前初始位置选择优先级（defaultST、playedTime、片段跳过策略），准备期间用户新 seek 覆盖初始值；不要在原生 play 时无意重置 rate=1。禁止完成回调无条件 play。

监听 item status、timeControlStatus、waiting reason、loaded/seekable ranges、duration、失败和结束通知。正确移除 KVO、time observer、通知和旧 item；MainActor/串行所有权明确，所有异步完成检查 generation/disposed。

若为过渡暂时保留双 AVPlayer，必须同时处理启动、暂停、缓冲、seek 完成、倍速、恢复和漂移；标为未完成最终架构，不能靠修改阈值通过最终验收。

### 2.6 错误与回滚边界

以会话级 feature flag 控制整个新链路，错误分类为网络/鉴权、索引/封装、解码和呈现。允许先刷新失效 URL 或尝试同 representation 的备用 CDN；换兼容编码仍须保持真实画质/HDR 并尊重用户设置。不兼容时明确给出重试或用户可见的 SDR 选择，保留位置和播放意图；禁止自动退回仍有同步/截断缺陷的旧双播放器，禁止将原始 HDR 无保护地交给 8-bit 纹理后声称 HDR 成功。

### 阶段测试

纯 Swift parser/索引 fixture 测试：v0/v1、非零 first_offset、64 位 box、不完整头、嵌套索引、不同音视频时基、恶意长度；网络 fake 测试 206/200/416/短包/重试/取消；原生集成测试随机 seek、EOF、source replacement、prepare 后取消。增加测试 target 或可测试纯模块时，不引入生产二进制替换。

## 阶段 3：复用完整控制层并补齐命令

把画面 surface 与公共 overlay 分开。保留现有 SDR 样式及交互语义，只抽出必要层；不要为了 HDR 复制第二套顶部/底部控件。

逐一解除 PLVideoPlayer 的 mpv 强制解包、mpv stream 订阅、生命周期直调以及尺寸初始化依赖。原生准备状态、视频尺寸和当前状态来自统一快照，尚未 ready 时也应有可交互的暂停/退出/错误界面。

控制覆盖：点击显示/隐藏、底部进度条、拖动预览与最终 seek、双击播放暂停、长按/选择倍速、锁屏控件策略、音量/静音、亮度、横竖屏/全屏/返回、缩放/适应模式。不能单靠 native hitTest=nil 假定命中正确；验证 Flutter platform view 与 overlay 的实际事件路由和手势竞争。

统一所有命令入口，包括 seek 与 seekTo、弹幕/字幕点击跳转、初始续播、跳片头/片尾、媒体中心/远程控制和应用生命周期。seek 先校验与钳制，再只发给活动后端；后端返回完成/实际位置，快速多次 seek 以最后一次为准，不由旧回调覆盖新位置。不要固定把所有 seek 都改为零容差而忽视 4K seek 成本。

后台音频、PiP、音频中断/耳机变化需要按已有产品功能与后端能力明确处理：支持则由活动后端实现并回写统一状态；暂不支持就明确禁用/说明，不能按钮仍可点却控制隐藏 mpv，也不能因此悄悄启用第二播放器。生产交付所承诺的既有功能必须完成相应验收。原生 PiP 应绑定同一 AVPlayerLayer/session，不能拿 native viewId 冒充原 mpv textureId；保留 SDR 现有 PiP 适配。若后台策略允许继续播放，surface detach 不等于 backend dispose，应由页栈/owner token 与后台保留策略共同决定何时结束 session；最终所有者释放后 dispose 必须幂等。系统音量与播放器内部增益也要区分，不假定 AVPlayer 可实现 mpv 的所有增益功能。

测试至少覆盖：没有 mpv 实例时 overlay 可构建；tap 显示底控；拖动命令只发一次最终位置；倍速改变实际原生 rate；暂停期间切画质不偷播；HDR→SDR、SDR→HDR、HDR→HDR；音质/编码/分 P/快速返回；旋转与全屏不重播、不重复请求；返回后控制通道/观察者释放。

## 阶段 4：字幕、弹幕和业务状态

优先建立 typed SubtitleCue 模型：接口层解析 B 站真实响应 body，统一产生 cue 列表；mpv 按需将同一列表生成 VTT，原生 overlay 直接消费 cues。也可以实现可靠的 VTT parser，但只能选择并验证一种明确协议，不让返回格式靠调用者猜测。

不要只把调用改成 format=json：当前 JSON 分支未实现。兼容无字幕、错误 JSON、错误响应形状、VTT 输入误传、缺失/非法时间、重叠/多行/Unicode 文本与空内容；解析失败要有受控错误，不让 FutureBuilder 静默空白掩盖协议错误。

缓存键包含媒体/分 P、字幕轨道/语言及必要的 URL 版本，切轨/切源失效；异步字幕请求绑定 session，旧结果不覆盖新视频。Widget 初次挂载、cues/controller 改变、seek 和播放暂停后都重新计算当前字幕，订阅在 dispose 时释放。

统一时间契约时同步修改 NativeSubtitleOverlay，不能继续将本已是秒的 position 除以 1000。弹幕使用统一媒体时间推进，区分暂停/缓冲/seek/倍速，避免按系统墙钟累积漂移。

测试必须从脱敏的实际响应形状或接口 fixture 出发，贯穿接口→cues→mpv VTT/原生 overlay；已有仅测试手写 JSON 列表的用例不足以证明生产格式兼容。验证切字幕轨、同路由换分 P、字幕初次显示、回退 seek、字幕监听释放，以及已有弹幕和历史回归。

## 阶段 5：在正确后端上定位和修复 4K 性能

### 实验纪律

先完成后端隔离和观测归属，再测性能。每条记录带 session、活动后端、源 representation、codec/profile/bitdepth/HDR、源尺寸/帧率、输出尺寸、播放速率、渲染/同步配置和明确采样起止时间。

mpv 先查当前版本可用属性，再记录实际 hwdec-current、解码器、相关掉帧/延迟计数、缓冲、渲染信息等。AVPlayer 使用适用的访问/错误日志、timeControlStatus、stall 与可获得的帧信息及 Instruments；不能拿后台 mpv 的 hwdec-current 代替 AVPlayer 的实际解码证据。

同素材、同分 P、同画质/编码、同设备/屏幕状态、相近网络和热状态做 A/B，一次只改一个变量。建议每组预热 10 秒、连续采样至少 120 秒、重复至少 3 次；启动、seek、暂停、缓冲和稳态分别统计。这些是实验设计，不是现有测量结果。

掉帧计数先取窗口差值并检查重置。只有获得同一窗口含义明确的帧总数时才计算百分比；不能把每秒掉帧数写成百分比，不能随意相加语义重叠的 decoder/VO counters。没有可靠分母就报告掉帧数及每秒增量，不捏造比例。零 decoder-drop 不证明解码无瓶颈。

### 分层排查

1. 排除双后端、重复音频/网络与过期会话。
2. 核对实际硬解和支持的编码/profile，不只看设置字符串。iOS 默认 videotoolbox 保留，尊重用户关闭硬解及其他明确选择，不扩散到其他平台。
3. 分清网络等待、磁盘/缓存、硬解、像素转换/拷贝、纹理/表面、合成、UI 重建与同步调度；有证据再改对应层。
4. 审核输出尺寸变化次数及原生表面分配。VideoOutputResize 的 120ms 是 debounce，不是“每 120ms 必重建”；无调用次数/分配证据不得归因为频繁重建。
5. 若验证输出尺寸是瓶颈，在保留源分辨率、超分规则、BoxFit、裁剪、缩放和方向变化的前提下优化；避免重复传相同尺寸、竞态覆盖或无界重试。原生 AVPlayerLayer 不照搬 mpv 纹理参数。
6. video-sync、超分、输出大小等调整必须单变量验证，不能一次全部关闭后宣称找到根因。恢复实验设置，保留可复现且有收益的最小改动。

阶段完成条件：同等条件前后证据、根因与修复的因果支持、画质未暗降、音画同步未回退。没有排除热降频/网络差异的“更流畅”不算完成。

## 阶段 6：端到端验收与资源稳定性

下列数值是建议的初始工程门槛，不是用户提供的既有指标，也不是实测结论。执行前可依据设备/素材制定更严格且可复现的门槛；不得为把失败改成通过而事后放宽。

### 功能与时钟

- 控件点击、拖动、暂停/恢复、倍速、全屏、切画质等关键操作每项连续至少 10 次，操作确实影响显示画面的活动后端；没有重复播放/音轨或旧状态回跳。
- 统一位置/时长正确；正常播放 UI 进度更新延迟目标不超过 500ms。seek 的实际位置容差根据素材 GOP/所选策略明确，精确 seek 的目标可以先设为 500ms 以内；记录真实结果，不把“收到命令”当完成。
- 音画同步使用有已知音视频标记的合法测试素材和可解释的测量方式，稳态目标绝对偏差不超过 80ms；seek/缓冲恢复后目标在 3 秒内回到范围。单 AVPlayer 只有一个 currentTime，不能用两个 API 时间读数假装测得最终屏幕与扬声器同步。
- 没有相应声画测量能力时，报告已验证的时间轴/播放状态与尚未测得的感知偏差；不得编造毫秒值。

### 长视频与资源

- 至少连续播放 30 分钟并超过原有片段限制，另验证可 seek 到真实分 P 末尾；短片独立完整播放用于完成/连播测试。不要把多分 P 总时长当当前分 P 时长。
- 验证暂停等待、网络中断/恢复、后台/前台、系统音频中断、临近结尾和快速切源。
- 反复进出/切源至少 20 轮，观察活动播放器、监听、网络请求、内存与临时缓存变化；预算有上限，无持续线性增长。一次重启后内存释放不能证明无泄漏。
- 加载、seek、请求回调等任意阶段 dispose，后续不能重新 play、污染新状态或生成无人持有的临时文件。清理只针对本应用拥有且当前不在使用的文件，不误删新会话缓存。

### 真 HDR 与 4K 性能

- 用真实支持的设备验证源编码/位深/传递函数/色域、原生输出链路和系统能力；区分请求 EDR、系统支持 HDR 与当前实际 HDR 呈现。
- 与官方应用进行同素材、同清晰度/帧率、同设备亮度/显示设置的对照；普通截图可能被转换为 SDR，不能据其亮度判断 HDR 失败或成功。需要量化亮度时要有相应测量条件，没有就不报 nits。
- 不可用“无绿屏、颜色正常”替代 HDR 验收，不可把 HDR10 的成功推广成 Dolby Vision/AV1 HDR 全部成功。
- 在能力范围内验证 4K30/4K60、不同编码与 SDR/HDR，分别报告性能。输出不存在的测量为“未测”，不是零。

### 自动化和环境

为状态机/控制/字幕补 Dart 单测与 Widget 测试；为解析、索引、网络与取消补 Swift 测试；为原生通道、控制交互和切流补模拟器集成测试。真正播放性能与 HDR 走真机。

可参考以下命令，但先确认当前环境和脚本副作用，逐条检查退出码，不通过 tail/grep 片段隐藏失败：

```bash
FLUTTER=/Users/space/development/fl-3479/flutter/bin/flutter
"$FLUTTER" --version
"$FLUTTER" analyze
"$FLUTTER" test
"$FLUTTER" build ios --simulator --debug
"$FLUTTER" build ios --release --no-codesign
bash tool/verify_release_constraints.sh build/ios/iphoneos/Runner.app
```

实际 Swift/Xcode 测试命令依新增/现有 target 确定；记录完整 scheme、destination 和退出码。模拟器缺 runtime 时在现有权限内安装/配置；真机锁定或被占用时不绕过限制、不抢占使用，继续可完成的测试并保留未验收项。

## 阶段 7：发布纯净性、文档与最终交付

1. 清理临时 forced HDR/码流/同步选项、诊断 overlay、全局 debugNote、无开关日志和原生文件写入。必要的诊断采用受控、脱敏、有界机制；Release 不携带临时实验行为。
2. 扩展发布检查范围：Dart AOT、Runner/原生模块与运行后的诊断落盘均要检查；只扫少数 Dart 字符串不够。字符串扫描也不能单独证明没有诊断行为。
3. 从最终干净源码重新构建，记录提交/dirty diff、构建配置、时间与产物标识，再验证/安装该同一产物。不能测试旧 profile 包，交付一个从未运行的新 release 包。
4. 对最终设备包检查 Bundle ID、AV1 框架 ABI/符号和受保护二进制；签名只用现有授权配置。无签名构建能编译不等于可安装真机验证。
5. 更新相关可行性、AV1、输出尺寸说明和测试文档，去掉“固定 videotoolbox 就禁绝软回退”“AVPlayerLayer 是唯一公开 HDR 表面”“19 段不是限制”“已从短样本证明长期稳定”等过度表述。
6. 保留 source→backend→container/display 的实际能力矩阵，注明已验证的系统/设备/编码范围、明确不支持和未验证项；SDR 降级必须让用户知情，不能把它记成 HDR 成功。
7. 最后执行与本任务相关的完整回归，包含首页 StepGo/推荐政策及非 iOS 行为保护测试。不要把原有失败悄悄删除，也不要靠放宽断言使测试变绿。

## 四、严禁的伪修复

- 仅将 maxFragments 从 19 改大或删除后全量下载整片。
- 仅删掉时间的乘 1000，却仍由两后端写状态，或遗漏字幕/毫秒 getter。
- 仅停 mpv，却留下等待 mpv onInit 的原生页面和 UI 强制解包。
- 仅设置 native hitTest=nil，却没有挂载完整控制层。
- 每秒强制 seek 音频、缩小阈值，却不处理缓冲/准备/seek 完成和共享时钟。
- 把资源后缀改为 HLS、简单串接两个 init 或全局替换 hev1。
- 用更多轮 describe 代替可取消的生命周期订阅。
- 用换 key 解决一切，导致旋转/全屏也重新创建会话。
- 用 10-bit、EDR 请求、readyToPlay、截图或硬解配置字符串单独宣称真正 HDR/性能成功。
- 盲改 video-sync、关超分、降低画质、换依赖，让变量一起变化后宣称定位完成。
- 将源码修改、编译、单测、模拟器验证、真机行为和最终包验收混为一谈。

## 五、每个阶段必须提交的结果

每阶段说明：修复了什么根因；改动文件及理由；新增/更新测试；实际执行命令及退出码；可复现的观察证据；剩余不确定性；是否可以进入下一阶段。证据和日志必须脱敏。

最终逐项列出“代码已修复 / 自动测试已通过 / 模拟器已验证 / 真机已验证 / 最终产物已验收”。任一项未完成要写明具体条件，不能把“暂时没复现”写成“已解决”。

优先顺序是：先统一后端和状态，同时验证原生媒体适配；再完成公共控制、命令和字幕；在可信的活动后端上定位性能；最后进行持续播放、真实 HDR 和干净产物验收。不要先微调硬解选项再补基础架构。

# 提示词结束

---

## 官方技术依据与适用边界

以下资料用于确定方案边界，不代表当前仓库已经实现其要求：

- [Apple HLS Authoring Specification](https://developer.apple.com/streaming/hls-authoring-specification-for-apple-devices.html)：HEVC/HDR、fMP4、音轨、时基、CODECS/VIDEO-RANGE 等封装与清单约束；hvc1 等建议不能误读成所有系统对 hev1 的绝对禁用。
- [AVMutableComposition](https://developer.apple.com/documentation/avfoundation/avmutablecomposition)：可将已支持的 asset 轨道组合交给 AVPlayerItem，不证明任意 DASH 远程分离轨天然可播、可流式随机 seek。
- [AVAssetResourceLoader](https://developer.apple.com/documentation/avfoundation/avassetresourceloader)：协调 URL asset 的资源请求，不是 DASH 转换器或通用音视频合轨器。
- [Display HDR video in EDR with AVFoundation and Metal](https://developer.apple.com/videos/play/wwdc2022/110565/)：AVPlayer/AVPlayerLayer 是本项目优先采用的系统 HDR 路径，但并非平台唯一可能的 HDR 渲染路径。
- [CALayer.wantsExtendedDynamicRangeContent](https://developer.apple.com/documentation/quartzcore/calayer/wantsextendeddynamicrangecontent)：执行时检查实际 SDK 的可用性/废弃说明及替代动态范围 API，不能把该属性视为 HDR 成功开关。
- [AVPlayer.availableHDRModes](https://developer.apple.com/documentation/avfoundation/avplayer/availablehdrmodes)：能力信息与当前内容/当前显示效果是不同层次的证据。
