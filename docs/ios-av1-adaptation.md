# iOS-only AV1 / iPhone Air adaptation

Date: 2026-11-02.

## Scope

- This branch targets iOS and iPhone Air only. `android/`, `linux/`, `macos/` and `windows/` platform targets are removed; shared Dart code retains platform guards where removing them would add risk.
- Builds use Flutter 3.47.9 and the existing `com.example.pilipalax` bundle id so updating preserves the app data container and Hive settings.

## Update prompt

`BuildConfig.buildTime` is a compile-time define. A custom build without `pili.time` has value `0`, so `Update.checkUpdate` always treats the latest GitHub release as newer. The build must pass:

```sh
--dart-define=pili.name=<version>
--dart-define=pili.code=<build-number>
--dart-define=pili.hash=$(git rev-parse HEAD)
--dart-define=pili.time=$(date +%s)
```

`Update.checkUpdate` additionally skips the check when `buildTime <= 0`, preventing future metadata-less local builds from showing a false update dialog.

## AV1 hardware decode

The stock iOS libmpv build uses FFmpeg 7.0.2 without `av1_videotoolbox`; AV1 falls back to libdav1d (software). Replace only `Avcodec.framework/Avcodec` with an FFmpeg 7.0.2 build containing the upstream AV1 VideoToolbox backport (FFmpeg commit `f9c5c5358cfef3847674c6f3b3ded9611ebc5647`). The replacement keeps ABI `61.3.100`, the original 359 exported symbols, and the original dependent frameworks.

Runtime contract:

- mpv option `hwdec-codecs=all`;
- PiliPlus hardware mode `videotoolbox,auto-safe`;
- codec preference `AV1, HEVC, AVC` on iOS (the default for new installs), see "Codec priority";
- buffer 256 MB / 30 s.

The patched AV1 framework was validated to contain the AV1 VideoToolbox symbols and to export exactly the same 359 symbols as the stock framework. On an iPhone Air, a 4096x2160 AV1 stream reported:

```text
codec: av1
hwdec=videotoolbox
VideoParams(pixelformat: videotoolbox, hwPixelformat: nv12, w: 4096, h: 2160)
TextureGL: resize: 4096.0x2160.0 -> 1260.0x665.0
```

This confirms AV1 4K hardware decode and #3088 output resizing on the target device.

## Rendering / heat

- #3088 resizes the native output to the fitted display area instead of keeping a full 4K texture. On an iPhone Air portrait player, the native output settles around 1260x665 instead of 4096x2160.
- `#3088` is active only when hardware decoding is enabled and super resolution is disabled.
- AV1 and HEVC 4K both run on VideoToolbox; Dolby Vision/HDR should be selected only after the display/decoder path is verified.

## Codec priority

`Pref.defaultPreferCodecs` returns `AV1, HEVC, AVC` on iOS and keeps the
upstream `AVC, AV1` order elsewhere. AV1 comes first on iOS because:

- VideoToolbox decodes it through the patched Avcodec build (verified below), so
  it is not the software fallback it used to be;
- it is royalty free and typically 10-30% smaller than HEVC at the same quality
  on Bilibili's ladder;
- every iPad/iPhone that runs this branch ships the same injected framework.

HEVC stays second so streams without an AV1 rendition, and Dolby Vision
profiles (`DVH1`), still resolve in one step. Users with an existing
`preferCodecs` value keep it: the getter only applies the new default when the
setting box has no entry. `HEVC, AVC, AV1` remains one tap away in
设置 → 播放设置 → 首选解码格式.

## iPhone Air UI

iPhone Air reports a 420 x 912 logical viewport (1260 x 2736 at DPR 3). Dialogs use a responsive width capped at 420 and at viewport width minus 32; the previous fixed 420 width had no side margin on this device.

`test/common/iphone_air_layout_test.dart` pins the audited geometry: the
DPR-3 viewport resolves to 420 x 912, `Style.dialogFixedConstraintsFor` keeps at
least 32 pt of side margin in both portrait and landscape, and the quality /
codec / ordered-multi-select dialogs render inside the viewport with long
Chinese labels. `test/utils/video_codec_priority_test.dart` covers the codec
ladder (`AV1` wins, `HEVC` and `AVC` fall back, `DVH1` stays ahead of SDR).

## CI

`.github/workflows/ios.yml` runs the upstream release build
(`lib/scripts/build.ps1` writes `pili_release.json` with `pili.name/code/hash/time`,
so CI builds already carry the metadata that suppresses the update prompt) and
now also swaps in the AV1 Avcodec before re-signing:

```sh
cp ios/av1/Avcodec build/ios/iphoneos/Runner.app/Frameworks/Avcodec.framework/Avcodec
plutil -replace MinimumOSVersion -string 15.0 \
  build/ios/iphoneos/Runner.app/Frameworks/Avcodec.framework/Info.plist
```

The injection has to happen after `flutter build ios` and before the ad-hoc
`codesign` loop, so the ad-hoc signature covers the replaced binary. The 3.4 MB
framework is committed (`ios/av1/Avcodec`), so no external download is needed.

Local signed builds keep using `tool/build_ios_av1.sh`, which performs the same
swap plus a real identity/provisioning-profile signature.

## Continuous-playback evidence (iPhone Air, iOS 27.2)

Instrumented builds 5592/5594 carried temporary `Utils.reportError` probes that
wrote decoder state into `Documents/.pili_logs.json`; they were removed again
before the shipped build (5595). A 36-minute AV1 4K session reported:

```text
DIAG vparams pixfmt=videotoolbox hw=nv12 3840x2160 hwdec=videotoolbox
DIAG tick pos=30s   hwdec=videotoolbox pixfmt=videotoolbox out=3840x2160
DIAG tick pos=1530s hwdec=videotoolbox pixfmt=videotoolbox out=3840x2160
DIAG tick pos=2130s hwdec=videotoolbox pixfmt=videotoolbox out=3840x2160
DIAG lifecycle=inactive hwdec=videotoolbox pixfmt=videotoolbox
DIAG lifecycle=resumed  hwdec=videotoolbox pixfmt=videotoolbox
DIAG lifecycle=hidden   hwdec=videotoolbox pixfmt=videotoolbox
DIAG lifecycle=paused   hwdec=videotoolbox pixfmt=videotoolbox
DIAG output rect=1260x709 source=3840x2160
```

- `hwdec-current` stayed `videotoolbox` in every sample and across
  background → foreground plus danmaku toggles: no software fallback.
- `DIAG output rect=1260x709 source=3840x2160` confirms #3088 resizes the native
  output to the fitted area instead of keeping a 3840x2160 texture (the
  1260x665..709 band is expected for 16:9 in the portrait player).
- The device stayed on the charger (`ExternalConnected=1`), so the battery
  percentage is not a usable heat proxy; no frame showed brightness dimming.

## Verification checklist

1. Playback info shows `codec: av1` (default on iOS) or `hevc` and `hwdec: videotoolbox`.
2. `TextureGL: resize` settles near the fitted physical size, not 3840x2160.
3. 4K playback remains smooth while scrolling danmaku/comments; check thermal behavior over at least 10–15 minutes.
4. Background/foreground and quality/codec switches retain hardware decoding.
5. Settings and login survive updates; no false update prompt appears.

Status on 2026-11-02 (iPhone Air, iOS 27.2, builds 5581 to 5596):

| Check | Result |
| --- | --- |
| hwdec videotoolbox on a 4K AV1 stream | pass, held 36 min and across lifecycle switches |
| Output texture resized to the fitted area | pass, rect=1260x709 from 3840x2160 |
| 420x912 layout | pass, 10 audited screens, 0 out-of-bounds nodes, 0 framework errors |
| Settings/login preserved across 8 upgrades | pass, preferCodecs/hardwareDecoding/buvid intact |
| No false update prompt | pass (metadata build, empty error log) |
| Repeatable signed build | pass, 5589 to 5596 from tool/build_ios_av1.sh |
| HDR / Dolby Vision stream | not exercisable: the test upload exposes only AVC renditions to an anonymous session; fallback covered by test/utils/video_codec_fallback_test.dart |
| Battery/thermal curve | not measurable: the device stayed on the charger during the run |
