# 无线连接 iPhone（本项目默认调试通道）

本项目后续统一走 **WiFi 无线**连接真机，不再依赖 USB。本文记录已验证的步骤、
判据和排障顺序。网络环境变化（IP 段、路由器、切换 WiFi）时按「环境变化」一节处理。

> 本文的描述来自一次实测通过的连接：USB 已拔除、`system_profiler` 的 USB 总线上
> 0 台 iPhone，而安装、启动、截图、抓日志全部成功。未经验证的步骤不会写进来。

## 一、一次性配对（只需做一次）

无线调试**必须先用 USB 完成一次配对**，配对信息由手机保存。

1. USB 连接 iPhone，手机上出现「信任此电脑」时选择信任
2. 打开 Xcode，菜单 **Window → Device Hub**（Xcode 27 起不再叫
   "Devices and Simulators"，Window 里找不到旧名字的项）
3. 在 Device Hub 左侧选中该 iPhone，勾选 **Connect via network**
4. 出现网络图标后即可拔掉 USB

配对完成后，Xcode 关闭、Mac 重启都不需要重做这一步。

### Xcode 27 的界面变化

| 旧（Xcode 26 及更早） | 新（Xcode 27+） |
| --- | --- |
| Window → Devices and Simulators | Window → **Device Hub** |
| 快捷键 ⇧⌘2 | 无对应快捷键，⇧⌘2 现在打开 Welcome 窗口 |

这点很容易踩：旧教程给的菜单名和快捷键在 Xcode 27 上都是死的，会让人误以为功能被移除。

## 二、日常使用

配对过一次之后，只要 Mac 与 iPhone 在同一局域网，`devicectl` 就能直接操作设备，
无需任何 USB：

```bash
DEV=00008150-001E5C592E78401C

xcrun devicectl device install app --device $DEV build/ios/iphoneos/Runner.app
xcrun devicectl device process launch --device $DEV --terminate-existing com.example.pilipalax
xcrun devicectl device capture screenshot --device $DEV --destination /tmp/shot.png
xcrun devicectl device copy from --device $DEV \
  --domain-type appDataContainer --domain-identifier com.example.pilipalax \
  --source 'Library/Application Support' --destination /tmp/logs
```

注意 `--source` 的值含空格时必须加引号，否则会被拆成两个参数。

## 三、如何确认当前走的是无线

**不要只看 `transportType`**：即使 USB 已拔除，CoreDevice 仍可能报告
`transportType = wired`，这是它的枚举值，不代表物理连接。

可靠的判据是 USB 总线：

```bash
system_profiler SPUSBDataType | grep -ci iphone
```

- 输出 `0` 且设备能正常安装/启动 → **确认是无线**
- 输出 `1` → 仍是有线

设备状态应为 `connected`（不是 `unavailable`）：

```bash
xcrun devicectl list devices | grep -i 'iphone Ultra'
```

## 四、环境变化（换 WiFi / 换路由器 / IP 段变更）

配对信息与 IP 无关，所以换网络**不需要重新配对**。只有发现不到设备时才需要处理。

1. **先确认同一局域网**：Mac 与 iPhone 连的是同一个 SSID（注意别连到访客网络或 5G/2.4G 隔离的 SSID）
2. **设备是否在线**：

   ```bash
   xcrun devicectl list devices | grep -i iphone
   ```

   - `connected` → 直接可用
   - `unavailable` → 手机可能锁屏或已休眠，点亮屏幕后重试
3. **Bonjour 是否能看到设备**：

   ```bash
   dns-sd -B _remotepairing._tcp local
   ```

   能看到条目说明广播正常；完全看不到说明两台设备不在同一可互通的网段。

4. **主机名可能对不上，这是已知现象**

   Bonjour 广播的名字与 `devicectl` 记录的名字可能不同：

   ```
   Bonjour 实际广播 : FredmatoiPhone-Ultra.local
   devicectl 记录   : FreddeiPhone-Ultra.<uuid>.coredevice.local
   ```

   此时 `ping` 或 `devicectl --device <dns_name>` 会失败（error 1000），
   **这不代表设备不可用**。用 UDID 寻址即可，本文所有命令都用 UDID。

5. 仍连不上时，回到 USB：重新插拔，确认 Device Hub 里网络图标仍在，再拔掉。

## 五、排障顺序（按此顺序，不要跳步）

| 顺序 | 检查 | 命令 | 结论 |
| --- | --- | --- | --- |
| 1 | 设备状态 | `devicectl list devices` | `connected` 则可用 |
| 2 | 是否真无线 | `system_profiler SPUSBDataType \| grep -ci iphone` | 0 = 无线 |
| 3 | 配对状态 | `devicectl device info details --device $DEV` | `pairingState: paired` |
| 4 | 广播可见性 | `dns-sd -B _remotepairing._tcp local` | 有条目 = 同网段 |
| 5 | 端到端 | 安装并启动一次 | 成功即通道可用 |

### 不要做的事

- **不要为了连设备去改路由、DNS 或代理设置**。实测本网段路由正常
  （`route -n get 192.168.5.1` 指向 `en0`），代理只接管默认路由与 `128.0/1`，
  不干扰局域网。动这些会带来中断风险，且与问题无关。
- 不要因为 `ping` 主机名不通就断定设备离线，见上文第 4 点。

## 六、实测记录（2026-11-05）

| 项 | 结果 |
| --- | --- |
| USB 总线 iPhone 数 | 0 |
| `devicectl list devices` | `connected` |
| 安装 | 成功 |
| 启动 | 成功 |
| 连续 5 次 `info details` | 5/5 响应 |
| 截图 | 成功（约 2 MB） |
| 抓取应用容器日志 | 成功 |
