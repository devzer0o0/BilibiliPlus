# 应用图标与启动画面

## 现在的图标是一个原创标记

![Bilibili+ 标记](../../assets/images/logo/logo.png)

图形由几何构成：一根竖笔加两个圆角"碗"组成 **B**，右上角一个青色 **+**，
底色是深海军蓝到品牌蓝的对角渐变。它是为本项目画的，不是任何官方图标的复刻、
描摹或改色。

母版只有两份，都是 SVG（矢量，改一次即可重出全尺寸）：

| 文件 | 用途 | 透明 |
| --- | --- | --- |
| `assets/images/logo/bilibiliplus-mark.svg` | iOS / macOS 图标、README | 否（全幅底） |
| `assets/images/logo/bilibiliplus-mark-transparent.svg` | Android 前景图、启动图 | 是 |

## 为什么不再使用旧图

之前的图标是把 bilibili 国际版 App Store 图标的粉色渐变替换成蓝色得到的复刻图。
它有两个问题：一是他人商标的再发布，二是项目改名为 **Bilibili+** 之后，那张图与
这个名字没有任何关系。

旧图连同它的对比图一并删除，仓库里不再保留：

- `docs/images/app-icon-bilibili-blue.png`
- `docs/images/app-icon-bilibili-intl-original.png`
- `docs/images/app-icon-comparison.png`
- `docs/images/app-icon-installed-120.png`

## 唯一产出途径：tool/generate_app_icons.sh

```sh
tool/generate_app_icons.sh
```

脚本做五件事，每一步都能失败：

1. 用无头 Chrome 把两份 SVG 渲染成 1024×1024 母版（`logo.png` 不透明、
   `logo_2.png` 透明），并打印尺寸与 alpha；
2. 跑 `flutter_launcher_icons`（由 `flutter_launcher_icons.yaml` 限定为 iOS），
   生成 **21 个** 图标尺寸，数量不是 21 就直接失败；
3. 从透明母版生成 **6 张** 启动图（浅色/深色 × 1x/2x/3x）；
4. 重出桌面窗口图标（`desktop/logo_large.png`）与 Windows 的 `.ico`（16/24/32/48/64/128/256），
   否则旧平台会继续显示上一版图形；
5. 打印母版与两张代表图标的 SHA-256，便于核对"确实重出了"。

```text
== 1. masters ==
  assets/images/logo/logo.png            1024x1024  alpha=no
  assets/images/logo/logo_2.png          1024x1024  alpha=yes
== 2. iOS app icons (21 sizes) ==
  21 icons regenerated
== 3. launch images (light + dark) ==
  LaunchImage.png            128x128
  ...
ICONS_REGENERATED
```

为什么不是"换掉 1024 那张，小图自然跟着变"：iOS 的 `AppIcon.appiconset` 里是 21 个
独立 PNG，Xcode 不会从大图派生小图。只替换大图时，桌面图标会继续显示旧图，
而仓库里看不出区别——这正是这次要修的问题。

## 覆盖的尺寸

- `ios/Runner/Assets.xcassets/AppIcon.appiconset/`：**21 个尺寸全部重新生成**
  （20×20 到 1024×1024）。
- `ios/Runner/Assets.xcassets/LaunchImage.imageset/`：**6 张全部重新生成**
  （128/256/384，浅色与深色各一套）。

## 启动画面

### 无法移除，只能替换

iOS 强制要求提供 launch storyboard（`Info.plist` 的 `UILaunchStoryboardName`），
因此"去除启动动画"在平台层面不可行。改为把它做快、做对：

1. **图标替换** — 启动图与桌面图标由同一次 `tool/generate_app_icons.sh` 生成，不会出现两套图形。
2. **底色修正** — 启动底色原为纯白，深色主题下会先白闪一下再进 App。已改为纯黑，与 `scaffoldBackgroundColor: Colors.black` 衔接。
3. **图形处理** — 启动图改为圆角 + 透明背景，避免在黑底上出现一块方形蓝块。

### 启动耗时实测

在 `main()` 中加了阶段计时（`_markStartup`），三次冷启动结果一致：

| 阶段 | 耗时 |
| --- | --- |
| binding + mediakit | 起始 |
| appPath | 12 ms |
| storage | 22 ms |
| paths + cache + fonts | 29 ms |
| orientation + locator + pip | 31 ms |
| request-init | 31 ms |

Dart 侧到 `runApp` 仅 **31 ms**。整体冷启动约 2.0–2.6 秒，其余时间花在 Flutter 引擎启动与首帧渲染上，
不在 `main()` 的初始化里。因此进一步压缩启动耗时不能靠裁剪初始化代码。

## 应用名称

`ios/Runner/Info.plist` 中 `CFBundleDisplayName` 与 `CFBundleName` 均为 `bilibili+`。
设备端 `devicectl device info apps` 已确认显示为 `bilibili+`。

Bundle ID 保持 `com.example.pilipalax` 不变。
