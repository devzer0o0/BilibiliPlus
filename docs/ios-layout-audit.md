# iPhone Air (420x912) layout audit

Date: 2026-11-03. Simulator: iPhone Air, iOS 27.2, DPR 3 (1260x2736).

## How the audit runs

`tool/tests/seed_account_test.dart` seeds a logged-in account into the
simulator container, so the audit can reach member-only surfaces without
manual steps. Each screen is then driven through idb's accessibility tree
(`idb ui describe-all`), which reports a frame for every element, and the
resulting JSON is checked for elements outside `0..420 x 0..912`.

```sh
xcrun simctl launch <udid> com.example.pilipalax
/tmp/idbenv/bin/idb ui describe-all --udid <udid>
```

Note: `idb ui swipe` needs an explicit duration to scroll Flutter lists:
`idb ui swipe --duration 0.6 --delta 10 210 780 210 180`. The default timing
completes too fast and the list snaps back.

## Result

| Area | Screens | Out-of-bounds elements |
| --- | --- | --- |
| Main tabs (home, dynamics, mine, hot, pgc, live) | 6 | 0 |
| Settings pages (privacy, recommend, danmaku, reply, appearance, other, about, AV) | 11 | 0 |
| AV settings dialogs (codec, hwdec, buffer, video-sync) | 4 | 0 |
| Download panel + quality dropdown | 3 | 0 |
| Favourite save panel | 1 | 0 |
| Long-text screens (video page, comments x3, danmaku) | 6 | 1 false positive |

The single flagged element is `有, 没有的有` at x=411 - an iOS keyboard
candidate, not app layout. It disappears when the keyboard closes.

## Issues found and fixed

### Bottom safe area counted twice

`MainLayout` pins the nav bar to the screen edge and `NavigationBar` applies
its own `SafeArea`, but the wrapper only removed the top inset. On iPhone Air
the destination row sat at `bottom=878` on a 912 pt screen, leaving a 34 pt
empty strip (the home-indicator height) below the labels. Removing the bottom
inset too moves it to 912.

### HDR reachable from the settings pickers

The in-player quality sheet was gated, but the default-quality dialog, the
cellular dialog and the download dropdown still listed 125/126/129. A stored
HDR default would bring the green stream back on every later video.

### Hardware-decoding list ignored the platform

`HwDecType.values` enumerated every mpv backend, so on iPhone the dialog
opened with DirectX, DXVA2, VAAPI, VDPAU, CUDA, QSV and Rockchip rows before
`videotoolbox`. `HwDecType.valuesForPlatform` keeps the generic modes plus the
backends for the running OS; the iOS list is six rows instead of 30+.

## What this audit cannot cover

The simulator forces `enableHardwareAcceleration = false`, so VideoToolbox
paths (4K/8K AV1 hardware decode, HDR `p010` handling) are not exercised here.
Those were verified separately on a physical iPhone Air; see
[ios-av1-adaptation.md](ios-av1-adaptation.md).