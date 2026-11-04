# 本轮实机/模拟器验证记录（2026-11-04 晚）

本轮尝试了真机验证，并在模拟器上取得了可复现的数值证据，同时**发现并修复了一个由本轮
改动引入的回归**。所有结论都标注了取得方式与不可外推的部分。

## 1. 真机：BLOCKED

设备 iPhone Air（iPhone18,4），UDID `00008150-001E5C592E78401C`，用户已解锁并接入 Wi-Fi。

探测结果（可复现）：

| 检查 | 结果 |
| --- | --- |
| `xcrun devicectl list devices` | `unavailable` |
| `connectionProperties.tunnelState` | `unavailable` |
| `xcrun devicectl device process launch` | CoreDeviceError 4016（usage assertion 失败） |
| `xcrun devicectl manage pair` | CoreDeviceError 4000（could not establish connection） |
| mDNS `_apple-mobdev2._tcp` | 有广播（`52:03:e5:92:7f:e5` → `Artemis.local:32498`） |
| mDNS `_apple-coredevice._tcp` | **无广播** |
| `ping Artemis.local` | 通（172.16.0.25） |
| TCP 62078（lockdown） | 通 |
| TCP 32498（CoreDevice 远程通道） | **connection refused** |
| `idevice_id -l -n` / `ideviceinfo -n` | 无设备 |

结论：设备在网络上可达，lockdown 服务在线，但 **CoreDevice 远程配对通道没有建立**，
因此无法安装或启动 App。这属于环境前置条件，不是被测产品的问题，也不能靠脚本绕过
（脚本不解除锁屏、不重启设备、不改安全设置）。

解除方式（任一）：用数据线连接并信任本机以重建通道；或在 Xcode → Devices and Simulators
中对该设备勾选 "Connect via network" 并等待配对完成。

**因此 D1/D2/D3/D4 全部仍为 NOT RUN。**

## 2. 模拟器：取得了数值证据，并发现一个真实回归

环境：iPhone Air 模拟器（iOS 27.2），App 由当前源码构建并重新安装（不是旧包）。

### 2.1 发现：125（HDR）在模拟器上出画后画面冻结

首轮 `tool/playback_check.sh BV1b24y1w73N 125 0 1`：

```
QA_PICK prefer=125 picked=125 codec=HEVC
f0 RGB=(109,108,101)
f1 RGB=(57,48,57)  hash e8d6a16a045a3a9e
f2 RGB=(57,48,57)  hash e8d6a16a045a3a9e   <- 与 f1 完全相同
```

三帧里后两帧哈希相同 = 画面停住。原因不是色偏，而是我这轮把
`eligibleForHDRPlayback` 当成了"可呈现"：模拟器跑在支持 HDR 的 Mac 上，该值为真，
但当前输出没有任何 HDR 模式，PQ 轨道能解码却无法合成。

### 2.2 修复

新增 `HdrCapability`（纯 Swift，可离线测试）：

- 有 `availableHDRModes` 时以它为准（描述当前输出通路）；
- 没有该 API 的 iOS 15/16 才退回 `eligibleForHDRPlayback`，避免把能播 HDR 的设备误判；
- 原因分两种：「当前输出通路没有可用的 HDR 显示模式」与「该设备不支持 HDR 播放」。

### 2.3 修复后复测（同一素材、同一构建流程）

```
HDR_PATH eligible=false modes=0 canPresent=false reason=当前输出通路没有可用的 HDR 显示模式
QA_PICK prefer=125 picked=120 codec=avc1.640034
f0/f1/f2 RGB 均 ok，三帧哈希互不相同
```

即：请求 125 时按规则回退到同分辨率 SDR 并正常播放，不再出现冻结。

### 2.4 4K SDR 连续播放（90 秒窗口）

`tool/continuous_playback_check.sh BV1b24y1w73N 120 90`：

| 项目 | 结果 |
| --- | --- |
| 采样次数 | 18（每 4 秒一次，覆盖 90 秒） |
| 画面变化次数 | 17 |
| 重复帧次数 | 0 |
| 画面分类 | 全部 ok（无黑屏、无绿屏） |
| 实际选中 | `picked=120 codec=avc1.640034`（4K SDR / AVC） |
| HDR 通路 | canPresent=false，按预期不路由 |

上限说明：这是**画面持续性**证据，不是帧率/丢帧证据；模拟器不跑 VideoToolbox，
不能外推到真机解码性能。

### 2.5 反复进入/退出（6 轮）

`tool/churn_check.sh 6 BV1b24y1w73N`：

```
round 1 MOVING alive=1
round 2 MOVING alive=1
round 3 MOVING alive=1
round 4 STATIC alive=1
round 5 MOVING alive=1
round 6 MOVING alive=1
RESULT=NO_CRASH_OBSERVED
```

6 轮进程全部存活，5 轮画面在动；第 4 轮画面静止（未展开为崩溃）。脚本明确不输出内存数字：
模拟器 RSS 不能代表真机，编一个数字比没有更糟。

### 2.6 切源保持意图（自动化）

`test/plugin/source_switch_intent_test.dart` 4 项通过：

- 暂停状态切画质后仍暂停（后端报告 playing 会被纠正为 pause）；
- 倍速 1.5 在切源后不被后端回报的 1.0 覆盖；
- 位置从 12:34 带入新源（`seek:754000`），不归零；
- 旧的慢请求最后完成也不覆盖新选择。

## 3. 本轮仍然 NOT RUN

- 真机 4K 连续播放 30 分钟、热状态、丢帧/硬解实测
- 音画同步测量（缺少闪光/短声素材与外部采集）
- 真机反复进出/切源 20 轮与资源计数
- 原生 PiP / 听视频 / 原生截图的交互验证
- 真机 HDR（PQ/HLG/DV/AV1 HDR）屏幕呈现

## 4. 构建与产物

- 模拟器包：`flutter build ios --simulator --debug`，本轮重新安装后取得上述数据。
- 真机包：`flutter build ios --release --no-codesign`，仅编译检查，不可安装。
- 已签名可安装产物：**BLOCKED_SIGNING**（未提供 Development Team）。
- Release 诊断隔离：`PILIPLUS_HLS_TRACE`、`PILIPLUS_HDR_TRACE`、`PILIPLUS_DIAGNOSTICS`、
  `HDR_PATH`、`QA_PICK` 在 Release 产物中均不存在。
- AV1 Framework 仍报 `binary differs from vendored Av1`：普通 `flutter build` 用的是 pod
  里的副本，需要 `tool/inject_ios_avcodec.sh` 注入本仓库的 `ios/av1/Avcodec`。
