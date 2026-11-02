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
- codec preference `HEVC, AVC, AV1` for normal playback;
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
- HEVC 4K is preferred; Dolby Vision/HDR should be selected only if the display/decoder path is verified.

## iPhone Air UI

iPhone Air reports a 420 x 912 logical viewport (1260 x 2736 at DPR 3). Dialogs use a responsive width capped at 420 and at viewport width minus 32; the previous fixed 420 width had no side margin on this device.

## Verification checklist

1. Playback info shows `codec: hevc` or `av1` and `hwdec: videotoolbox`.
2. `TextureGL: resize` settles near the fitted physical size, not 3840x2160.
3. 4K playback remains smooth while scrolling danmaku/comments; check thermal behavior over at least 10–15 minutes.
4. Background/foreground and quality/codec switches retain hardware decoding.
5. Settings and login survive updates; no false update prompt appears.
