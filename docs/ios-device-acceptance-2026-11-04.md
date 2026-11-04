# iOS 真机验收记录

本文件区分**历史记录**与**本轮（2026-11-04 之后）实际取得的证据**。历史部分保留原文，
因为它描述的是当时那台设备、那个构建；本轮没有重复那些测量，也没有把它们当作本轮的通过项。

设备：iPhone Air（iPhone18,4），iOS 27.2（24B119），UDID `00008150-001E5C592E78401C`。

---

## 本轮状态（先看这里）

| 验收项 | 状态 | 依据 |
| --- | --- | --- |
| 真机连接 | **BLOCKED_DEVICE_UNAVAILABLE** | `tool/device_preflight.sh` → `STATE=BLOCKED_DEVICE_UNAVAILABLE`，3 次有界重试后停止 |
| 4K 连续播放 30 分钟（D1） | **NOT RUN** | 设备不可用 |
| 流畅度/热状态对照（D2） | **NOT RUN** | 设备不可用 |
| 音画同步测量（D3） | **NOT RUN** | 设备不可用，且缺少闪光/短声测量素材 |
| 反复进出/切源 20 轮（D4） | **NOT RUN** | 设备不可用 |
| 原生 PiP（E1） | **未运行（设备阻塞）** | 代码 + 协调器单测完成 |
| 听视频（E2） | **未运行（设备阻塞）** | audioOnly presentation 编译通过 |
| 原生截图（E3） | **未运行（设备阻塞）** | `AVPlayerItemVideoOutput` 路径编译通过 |
| AirPlay 视频（E6） | **明确不支持** | loopback 媒体，已显式门禁 |
| 签名产物（C1） | **BLOCKED_SIGNING** | 未提供 Team ID；本轮产物是 `--no-codesign` 编译检查 |
| Release 诊断隔离（C4） | **自动化通过** | 产物中无 `PILIPLUS_HLS_TRACE` / `PILIPLUS_HDR_TRACE` |

本轮可复现的设备入口与阻塞原因：

```bash
bash tool/device_preflight.sh
# STATE=BLOCKED_DEVICE_UNAVAILABLE
# REASON=device 00008150-001E5C592E78401C not reachable after 3 attempts
```

解除阻塞需要：把 iPhone Air 用数据线连接到本机、解锁并信任这台 Mac。脚本不会解锁设备、
不会重启设备、也不会修改任何安全设置——前置条件不属于被测产品。

---

## 历史记录（2026-11-04 早些时候，当时的构建）

构建：`flutter build ios --release`（带签名，Team 8TQDS9JT23），Bundle ID `com.example.pilipalax`。
证据来源：`idevicesyslog` 直接取自设备；截图取自 `devicectl device capture screenshot`。

> 注意：该构建是本轮修改**之前**的代码。下面结论对本轮 HEAD 不成立，需要重新取证。

### 当时已验证

#### 1. 原生 HDR 链路在真机上确实工作

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

**这一条正是本轮 generation 修复要解决的问题的反面证据**：当时 AVPlayer 在出画，但 Dart 侧的
进度/缓冲事件被代次过滤丢弃。修复后的事件流需要用同样的 syslog 加应用内进度共同复核，本轮未做。

#### 2. 4K/HDR 样片在真机上出画

截图显示画面正常，无绿屏、无黑屏、无溢出横幅。

#### 3. 安装与产物

- `devicectl device install app` 成功。
- 签名包含本机 UDID 的 provisioning profile。
- `tool/verify_release_constraints.sh` 对当时那个包退出码 0。

### 当时未验证（现在仍未验证）

1. HDR 是否真实合成到屏幕。
2. 音画同步偏差。
3. 30 分钟连续播放、热状态、反复切源 20 轮。
4. Dolby Vision / AV1 HDR。
5. 原生 PiP / AirPlay（当时未实现）。

---

## 抓取方法（可复现）

```bash
# 1. 前置条件：设备已连接、解锁、已信任本机
bash tool/device_preflight.sh

# 2. 签名构建（需要 Team ID；不写入仓库）
PILIPLUS_DEVELOPMENT_TEAM=XXXXXXXXXX tool/ios_build.sh profile

# 3. 记录产物身份，确认测的是当前代码
bash tool/identity.sh build/ios/iphoneos/Runner.app

# 4. 安装 + 采集
DEV=00008150-001E5C592E78401C
xcrun devicectl device install app --device $DEV build/ios/iphoneos/Runner.app
(timeout 90 idevicesyslog -u $DEV > /tmp/syslog.txt &)
xcrun devicectl device process launch --device $DEV --terminate-existing \
  --payload-url 'bilibili://video/BV1b24y1w73N' com.example.pilipalax
grep -E 'VideoRange PQ|StartTrackPlaying|duration changed' /tmp/syslog.txt

# 5. 解码/丢帧测量（表格留空 = 没测到，不是 0）
bash tool/decoder_measure.sh BV1b24y1w73N 180
```

注意：debug 构建无法从桌面独立启动（iOS 14+ 限制，必须经 `flutter run`/Xcode）；真机验证使用
profile 或 release 包。`--no-codesign` 产物只能用于编译检查，不能安装。
