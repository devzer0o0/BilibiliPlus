# iOS 真机验收记录（2026-11-04）

设备：iPhone Air（iPhone18,4），iOS 27.2（24B119），UDID `00008150-001E5C592E78401C`。
构建：`flutter build ios --release`（带签名，Team 8TQDS9JT23），Bundle ID `com.example.pilipalax`。
证据来源：`idevicesyslog` 直接取自设备；截图取自 `devicectl device capture screenshot`。

## 已验证

### 1. 原生 HDR 链路在真机上确实工作

捕获到的 AVFoundation 播放决策（`mediaplaybackd` / MediaToolbox，14:16:17）：

```
fpfs_ReportVariantSwitchStart: starting switch up from [Pathway (null)]
  to [<FigAlternate(0): [Peak 1] [3840x2160] [AudioGroup aud]
       [hev1.2.4.L153.90] [VideoRange PQ] [FrameRate 58.824]>]
segPumpUpdateDurationIfChanged: duration changed - old is 0 new is 97.299
fpfs_StartTrackPlaying: ordered rendering for track 1 from 0 to 0.05; should preroll 1
fpfs_StartTrackPlaying: ordered rendering for track 2 from 0 to 4.608; should preroll 0
```

可证明范围：

- 选中变体是 HEVC Main10（`hev1.2.4`）、VideoRange PQ（HDR10）、3840x2160、58.824fps，不是 SDR 回落。
- 清单时长 97.299s 与本机对同一 `sidx` 的解析结果（97.3s）一致，播放的是整条轨道而非被截断的前 19 段。
- 视频与音频两条轨都进入 ordered rendering 并完成 preroll，说明是一个播放项同时承载音视频。
- 来源是本机 loopback：225 次连接指向 `127.0.0.1:60889`，`mediaplaybackd` 的 `coremedia_hls` 域被激活；`Mpv.framework` 只在 amfid 签名校验阶段出现，没有 mpv 打开媒体的记录。

### 2. 4K/HDR 样片在真机上出画

截图显示画面正常，无绿屏、无黑屏、无溢出横幅。此前该路径因把秒当毫秒、强制解包 mpv、PQ 变体被全部过滤而黑屏，三处均已修复。

### 3. 安装与产物

- `devicectl device install app` 成功。
- 签名包含本机 UDID 的 provisioning profile。
- `tool/verify_release_constraints.sh` 对真机包退出码 0：Bundle ID、Avcodec ABI 61.3.100、359 导出、原生与 Dart 诊断残留均为零。

## 未验证（不得当作已通过）

1. HDR 是否真实合成到屏幕：`VideoRange PQ` 变体被选中并渲染，与屏幕确实以扩展动态范围呈现是两件事。本轮没有分光/亮度测量，也没有与官方 App 的同素材对照；普通截图会被转成 SDR，不能据此判断。
2. 音画同步偏差：只验证了单 item 共享系统时钟的结构事实，没有声画测量数据。
3. 30 分钟连续播放、热状态、反复切源 20 轮：未做。
4. Dolby Vision / AV1 HDR：未单独验证；`hev1`→`hvc1` 修补只作用于 HEVC 路径。
5. 原生 PiP / AirPlay：未实现，原生路径上显式不启用而非静默失效。

## 抓取方法（可复现）

```bash
DEV=00008150-001E5C592E78401C
# 设备必须解锁且保持亮屏，否则 devicectl 拒绝启动
xcrun devicectl device install app --device $DEV build/ios/iphoneos/Runner.app
(timeout 90 idevicesyslog -u $DEV > /tmp/syslog.txt &)
sleep 3
xcrun devicectl device process launch --device $DEV --terminate-existing \
  --payload-url 'bilibili://video/BV1b24y1w73N' com.example.pilipalax
sleep 30
grep -E 'VideoRange PQ|StartTrackPlaying|duration changed' /tmp/syslog.txt
```

注意：debug 构建无法从桌面独立启动（iOS 14+ 限制，必须经 `flutter run`/Xcode）；真机验证使用 profile 或 release 包。
