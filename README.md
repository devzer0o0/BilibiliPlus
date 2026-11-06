<div align="center">
    <img width="180" height="180" src="assets/images/logo/logo.png" alt="Bilibili+ logo">
    <h1>Bilibili+</h1>
    <p><b>为 iPhone Air 深度优化的 B 站第三方客户端</b></p>
    <p>由 <a href="https://github.com/bggRGjQaUbCoE/PiliPlus">PiliPlus</a> 分叉而来</p>
    <p>AV1 / HEVC / H.264 硬件解码 · HDR10 / HLG · 杜比视界</p>

中文 | [English](README.en.md)

![GitHub repo size](https://img.shields.io/github/repo-size/devzer0o0/BilibiliPlus)
![GitHub Repo stars](https://img.shields.io/github/stars/devzer0o0/BilibiliPlus)
![GitHub all releases](https://img.shields.io/github/downloads/devzer0o0/BilibiliPlus/total)

<img src="assets/screenshots/510shots_so.png" width="32%" alt="home" />
<img src="assets/screenshots/174shots_so.png" width="32%" alt="player" />
<img src="assets/screenshots/850shots_so.png" width="32%" alt="comments" />
<br/>
<img src="assets/screenshots/main_screen.png" width="96%" alt="main screen" />
<br/>
</div>

<br/>

## 这一分支在做什么

从上游分叉之后，这个仓库的精力集中在一件事上：**让 iPhone Air 把视频解码真正交给硬件**，并在解不了的时候诚实地回退。

不是"打开一个开关"，而是四件事一起成立才算数：

1. 芯片支持 → VideoToolbox 报告能解 AV1；
2. **构建里真的有解码器** → 打包进 App 的 FFmpeg 注册了 `av1_videotoolbox`；
3. 选流选对了 → 优先挑能硬解的 AV1 变体，同时尊重你的编码偏好；
4. 播放时确实是硬件在解 → `hwdec-current=videotoolbox`，帧格式就是 `CVPixelBuffer`。

前两条任意一条不成立时，以前的结果是"App 说 AV1 可用，实际 3840×2160 全程 CPU 解码"，表现为发热、掉帧，而日志里什么都看不出来。现在这两条由构建直接卡死：**缺解码器就构建失败**，不给"静默降级"留口子。

<br/>

## 硬解与 HDR

<table>
<tr><th align="left">能力</th><th align="left">路径</th><th align="left">状态</th></tr>
<tr><td><b>AV1 8-bit SDR</b></td><td>mpv + FFmpeg + VideoToolbox</td><td>✅ 真机实测硬解（4K60 / 4K30，见下）</td></tr>
<tr><td><b>HEVC / H.264</b></td><td>mpv + VideoToolbox</td><td>✅ 真机实测硬解（含 4K60 回归）</td></tr>
<tr><td><b>HDR10 / HLG</b></td><td>AVPlayerLayer（原生 HDR 直通）</td><td>✅ 走原生路径，不做 8-bit 降级；本项目未逐档复测</td></tr>
<tr><td><b>杜比视界</b></td><td>AVPlayerLayer + RPU 由系统还原</td><td>✅ 路由到原生路径，不再被降成 SDR；本轮未复测具体片源</td></tr>
<tr><td><b>AV1 十位</b></td><td>AVPlayerLayer</td><td>▶️ 画面正确；硬解状态记 <code>unavailable</code>，不伪造</td></tr>
</table>

**实测记录（iPhone Air，iPhone18,4，iOS 27.3，签名 Release 之前的诊断构建）**

| 片源 | 规格 | 采样 | 硬解 |
| --- | --- | --- | --- |
| AV1 | 3840×2160 @60fps `av01.0.13M.08` | 31 | 31 |
| AV1 | 4096×2160 @59.994fps `av01.0.13M.08` | 32 | 32 |
| AV1 | 3840×2024 @59.932fps `av01.0.13M.08` | 32 | 32 |
| AV1 | 3840×2160 @29.97fps `av01.0.13M.08` | 2 | 2 |
| H.264 | 3840×2160 @60fps（回归） | 13 | 13 |

判定依据不是"我请求了 `hwdec=videotoolbox`"，而是播放器每帧回报的
`hwdec-current=videotoolbox` 与 libmpv 的 `vd: Decoder format … videotoolbox[nv12]`：
后者说明收到的帧**就是** VideoToolbox 的 `CVPixelBuffer`，不是先解到 CPU 再上传。

完整证据、构建身份、未测范围见
[docs/ios-av1-hardware-evidence-2026-11-05.md](docs/ios-av1-hardware-evidence-2026-11-05.md)。

<br/>

<img src="assets/images/readme/playback-pipeline.svg" width="100%" alt="iPhone Air playback pipeline">

<br/>

## 为什么是 iPhone Air

- **解码优先 AV1**：同等质量下比 HEVC 更省带宽，且在 iPhone Air 上确实由 VideoToolbox 解码，不再是"软解更烫"的那个 AV1。
- **两条后端各司其职**：8-bit SDR 走 mpv（弹幕、字幕、倍速、超分全套功能都在），HDR / 十位 / 杜比走 AVPlayerLayer（真正的 EDR 直通，不是把 HDR 压成 SDR 再假装）。
- **输出按显示区缩放**：4K 片源不再让 Flutter 纹理按 3840×2160 分配，播放页稳定在 1260×709 量级，省 GPU 与带宽。
- **为这块屏幕做的布局**：420 × 912 逻辑分辨率下的对话框、弹幕、选集、清晰度面板逐个量过边距，没有贴边和被裁的控件。
- **能力如实上报**：系统支持、构建支持、后端支持、本次会话是否真的硬解，是四个独立的答案；"不知道"既不当成支持，也不当成不支持。

> 追求的是"能证明"，不是"看起来可以"。所以这个 README 里的每个 ✅ 都带着采集方式，未测的项目直接写未测。

<br/>

## 构建与校验（iOS）

需要 Flutter 3.47.9、Xcode 27.x，以及一枚 Apple Development 证书。

```bash
# 签名 Release：自动注入 AV1 VideoToolbox 解码器、校验身份、重签
PILIPLUS_DEVELOPMENT_TEAM=XXXXXXXXXX tool/ios_build.sh release

# 只校验产物：解码器身份、导出符号集合、依赖库、诊断残留
tool/verify_release_constraints.sh build/ios/iphoneos/Runner.app
```

`tool/ios_av1_package.sh` 是所有构建入口（本地脚本、CI）共用的唯一实现。它替换 `Avcodec.framework` 之后会核对：

- **Mach-O UUID** —— 重签名改不了它，能区分"我们的解码器"和"pod 自带的";
- **完整导出符号集合** —— 不是数个数，是逐个比对;
- **依赖库** —— ABI 期望的库一个不多一个不少;
- **设备 / 模拟器 slice** —— 真机二进制不会被塞进模拟器包。

任何一项不成立，构建立即失败。

<br/>

## 图标与启动画面

App 图标与启动画面不再是"老图换个色"，而是一次重新设计：主体是 B 站百万粉丝纪念奖牌中央的**金色小电视**（宽圆角矩形机身、双天线、内凹屏框、浮雕眼嘴），由可编辑的 3D SDF 渲染器生成，不依赖图像生成模型、不裁剪照片。

- **设计母版**：`design/app_icon/master-2048.png`（2048²）为唯一定义源；1024 图标与透明小电视素材均由它派生，母版永不反向覆盖。
- **可重复管线**：`tool/app_icon/render_icon.py` 渲染母版 → `tool/app_icon/build_assets.py` 派生全部工程资源（iOS AppIcon 全尺寸、启动图、logo、ICO、Android 前景），ICC 时间戳固定，同输入逐字节同输出。
- **启动画面**：黑底 + 居中金色小电视。注意 iOS 会缓存启动 storyboard 快照——覆盖安装若仍见旧图，删除重装即可；详细机制见 [docs/app-icon-and-launch-screen.md](docs/app-icon-and-launch-screen.md)。
- **真机验收**：iPhone Air 上 0.0.3 (4) 已验证（运行截图、快照重建记录、Assets.car 内容），证据与未测范围（如 Android 旧 splash 图保留）同样记录在该文档。

<br/>

## 适配平台

- [x] iPhone Air（主要目标，逐项实测）
- [x] iOS / iPadOS
- [x] Android
- [x] Windows
- [x] Linux

[![Packaging status](https://repology.org/badge/vertical-allrepos/piliplus.svg)](https://repology.org/project/piliplus/versions)

<br/>

## 功能

<img src="assets/screenshots/home.png" width="24%" alt="home" />
<img src="assets/screenshots/media.png" width="24%" alt="media" />
<img src="assets/screenshots/bangumi.png" width="24%" alt="bangumi" />
<img src="assets/screenshots/set.png" width="24%" alt="settings" />

- [x] 推荐视频列表(app端)
- [x] 最热视频列表
- [x] 热门直播
- [x] 番剧列表
- [x] 屏蔽黑名单内用户视频
- [x] 无痕模式（播放视为未登录）
- [x] 游客模式（推荐视为未登录）

- [x] 用户相关
  - [x] 粉丝、关注用户、拉黑用户查看
  - [x] 用户主页查看
  - [x] 关注/取关用户
  - [x] 离线缓存
  - [x] 稍后再看
  - [x] 观看记录
  - [x] 我的收藏
  - [x] 站内私信

- [x] 动态相关
  - [x] 全部、投稿、番剧分类查看
  - [x] 动态评论查看
  - [x] 动态评论回复功能

- [x] 视频播放相关
  - [x] 双击快进/快退
  - [x] 双击播放/暂停
  - [x] 垂直方向调节亮度/音量
  - [x] 垂直方向上滑全屏、下滑退出全屏
  - [x] 水平方向手势快进/快退
  - [x] 全屏方向设置
  - [x] 倍速选择/长按2倍速
  - [x] 硬件加速（AV1 / HEVC / H.264，视机型与片源而定）
  - [x] HDR10 / HLG / 杜比视界原生呈现
  - [x] 画质选择（高清画质未解锁）
  - [x] 音质选择（视视频而定）
  - [x] 解码格式选择（视视频而定）
  - [x] 弹幕 / 字幕
  - [x] 记忆播放
  - [x] 视频比例：高度/宽度适应、填充、包含等
  - [x] 超分辨率

- [x] 搜索相关
  - [x] 热搜 / 搜索历史 / 默认搜索词
  - [x] 投稿、番剧、直播间、用户搜索
  - [x] 视频搜索排序、按时长筛选

- [x] 视频详情页相关
  - [x] 视频选集(分p)切换
  - [x] 点赞、投币、收藏/取消收藏
  - [x] 相关视频查看
  - [x] 评论用户身份标识
  - [x] 评论(排序)查看、二楼评论查看
  - [x] 主楼、二楼评论回复功能
  - [x] 评论点赞
  - [x] 评论笔记图片查看、保存

- [x] 设置相关
  - [x] 画质、音质、解码方式预设
  - [x] 图片质量设定
  - [x] 主题模式：亮色/暗色/跟随系统
  - [x] 震动反馈(可选)
  - [x] 高帧率
  - [x] 自动全屏
  - [x] 横屏适配

其余功能（动态、直播、私信、收藏夹、多账号、WebDAV 备份等）与上游保持一致：

- [x] 编辑动态 / 发布动态 / 转发动态 / 动态话题
- [x] 直播：分区、弹幕、表情、SuperChat
- [x] 私信：发图、删除/置顶/撤回、消息设置
- [x] 收藏夹：创建/编辑/删除、排序、复制移动
- [x] 多账号支持 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] WebDAV 备份/恢复设置
- [x] SponsorBlock / 高能进度条 / 跳过片头片尾
- [x] 视频截取动图 / Live Photo / 记笔记
- [x] 高级弹幕 / 合并弹幕 / 会员彩色弹幕

<br/>

## 下载

可以从 [Releases](https://github.com/devzer0o0/BilibiliPlus/releases) 下载，或克隆仓库拉取代码后在本地编译。

iOS 需要自备签名（见上文的构建脚本）；仓库不附带证书、描述文件或任何凭据。

<br/>

## 声明

此项目（PiliPlus）是个人为了兴趣而开发，仅用于学习和测试，请于下载后24小时内删除。
所用API皆从官方网站收集，不提供任何破解内容。
在此致敬原作者：[guozhigq/pilipala](https://github.com/guozhigq/pilipala)
在此致敬上游作者：[orz12/PiliPalaX](https://github.com/orz12/PiliPalaX)
本仓库做了更激进的修改，感谢原作者的开源精神。

感谢使用

<br/>

## 致谢

- [bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)
- [flutter_meedu_videoplayer](https://github.com/zezo357/flutter_meedu_videoplayer)
- [media-kit](https://github.com/media-kit/media-kit)
- [melodink-libmpv-darwin-build](https://github.com/gungun974/melodink-libmpv-darwin-build)
- [FFmpeg](https://ffmpeg.org/)
- [mpv](https://mpv.io/)
- [dio](https://pub.dev/packages/dio)

<br/>

## Star History

<a href="https://star-history.dera.page/#devzer0o0/BilibiliPlus&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://star-history.dera.page/svg?repos=devzer0o0/BilibiliPlus&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://star-history.dera.page/svg?repos=devzer0o0/BilibiliPlus&type=Date" />
   <img alt="Star History Chart" src="https://star-history.dera.page/svg?repos=devzer0o0/BilibiliPlus&type=Date" />
 </picture>
</a>
