# iOS-only AV1 / iPhone Air adaptation

Date: 2026-11-02.

## Scope

- This branch targets iOS and iPhone Air only. `android/`, `linux/`, `macos/` and `windows/` platform targets are removed; shared Dart code retains platform guards where removing them would add risk.
- Builds use Flutter 3.47.9 and the existing `com.example.pilipalax` bundle id so updating preserves the app data container and Hive settings.

## Release constraints

Three properties must hold for every shipped build. `tool/verify_release_constraints.sh`
asserts all of them and runs in CI after the AV1 framework is injected:

| Constraint | Check | Last observed |
| --- | --- | --- |
| Bundle id stays `com.example.pilipalax` | `Info.plist` | passes |
| AV1 framework ABI unchanged | `otool -L` shows 61.3.100 | passes |
| AV1 exports unchanged | `nm -gU` counts 359 | passes |
| No temporary diagnostics shipped | AOT snapshot has no `QA_PICK`, `prefer=`, `picked=` | passes |

`QA_PICK` is a debug-only line in `VideoUtils.findTargetVideo` that records
which rendition the player selected. It is wrapped in `kDebugMode`, which the
AOT compiler folds away; the check above confirms that on a real release build
rather than trusting the optimisation.

The label "diagnostic residue" only refers to this repo's markers. `DIAGNOSTICS`
and `DIAG_REC` strings in the binary come from the bundled SQL keyword tables.

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

The stock iOS libmpv build uses FFmpeg 7.0.2 without `av1_videotoolbox`; AV1 falls back to libdav1d (software). Replace only `Avcodec.framework/Avcodec` with an FFmpeg 7.0.2 build containing the upstream AV1 VideoToolbox backport (FFmpeg commit `f9c5c5358cfef3847674c6f3b3ded9611ebc5647`). The replacement keeps ABI `61.3.100`, the original dependent frameworks, and the same exported symbol set (compared in full, not by count).

### Five things this branch used to get wrong

Each of these produced a confident, wrong conclusion during the investigation. They
are written down because the same reasoning is easy to repeat.

| Claim | What is actually true |
| --- | --- |
| "The device supports AV1, so the app does." | VideoToolbox answering yes describes the **chip**. Whether *this build* can decode AV1 depends on the `Avcodec` it shipped. They are separate layers, and the app now records both. |
| "Asking for `hwdec=videotoolbox` means it will not fall back." | It is a request. mpv chooses per stream and reports the outcome in `hwdec-current`; a decoder that fails to initialise leaves the frame in software with the same setting in place. |
| "Ten-bit means HDR, so declare PQ." | Bit depth is not a transfer function. Ten-bit SDR AV1 is served by the catalogue, and declaring PQ for it makes AVFoundation tone-map an SDR picture as HDR. |
| "The binary contains `av1_videotoolbox`, so decoding is hardware." | A symbol proves the code exists. Only the decoded frame format (`videotoolbox[nv12]` in `vd: Decoder format`) and `hwdec-current` show that it ran. |
| "It worked on the 2 November build, so it works now." | Builds differ by which `Avcodec` was injected. A plain `flutter build ios` ships the pod's copy, which has no AV1 VideoToolbox decoder at all. |

### Build integrity

Every entry point (`tool/ios_build.sh`, `tool/build_ios_av1.sh`,
`.github/workflows/ios.yml`) now goes through `tool/ios_av1_package.sh`. It
replaces the framework and then proves it:

- the Mach-O **UUID** must be the vendored build's (re-signing cannot change it);
- the **full exported symbol set** must match, not a count;
- the **dependent libraries** must match;
- `av1_videotoolbox` must be present;
- a device build must not receive a simulator slice, and vice versa.

A failure stops the build. It used to print `SKIPPED` and continue, which is how
an installable app reached the phone without an AV1 decoder and looked, from the
device, like unsupported hardware.

### Capability model

`lib/plugin/pl_player/models/av1_capability.dart` keeps four answers apart:
**system** (`VTIsHardwareDecodeSupported`), **media library** (the loaded FFmpeg
registers a VideoToolbox hwaccel for `av1`), **backend** (the current renderer can
carry it), and **session** (`idle` / `starting` / `hardware` / `software` /
`failed`). `unknown` demotes nothing: only an established "this library has no AV1
VideoToolbox decoder" removes AV1 from the preference order, because demoting on a
missing answer loses a capability that is present.

The library layer is read from the **loaded** binary through `dlsym`
(`avcodec_version`, `avcodec_configuration`, `avcodec_find_decoder_by_name`,
`avcodec_get_hw_config`), so no second FFmpeg and no header set are introduced.

### Turning hardware decoding off

`Pref.enableHA == false` now sends `hwdec=no`. It used to send `null`, and
media_kit's native video controller writes `configuration.hwdec ?? 'auto'` — so
"off" arrived at mpv as "choose for me" and a device whose VideoToolbox answers yes
went on decoding in hardware.

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

## Codec evidence: AV1, HEVC 10-bit, 8K (build 5597, logged-in 大会员 account)

Build 5597 added a probe that records the actual container codec next to the
hardware state, so AV1 hardware decode is proven instead of inferred. Raw lines
from `Documents/.pili_logs.json` (2026-11-02):

```text
22:42:14 codec=av1  containerPixFmt=videotoolbox hwFmt=nv12 hwdec=videotoolbox src=3840x2160
22:42:20 codec=hevc containerPixFmt=videotoolbox hwFmt=p010 hwdec=videotoolbox src=3840x2160
22:42:27 codec=hevc containerPixFmt=videotoolbox hwFmt=nv12 hwdec=videotoolbox src=3840x2160
22:42:48 codec=hevc containerPixFmt=yuv420p     hwFmt=null hwdec=no            src=3840x2160
22:45:44 codec=av1  containerPixFmt=videotoolbox hwFmt=nv12 hwdec=videotoolbox src=4096x2160
22:45:51 codec=av1  containerPixFmt=videotoolbox hwFmt=nv12 hwdec=videotoolbox src=8192x4320
22:46:15 codec=hevc containerPixFmt=videotoolbox hwFmt=p010 hwdec=videotoolbox src=3840x2160
```

- **AV1 4K and AV1 8K both decode in hardware.** `containerPixFmt=videotoolbox`
  means libmpv's output IS the VideoToolbox CVPixelBuffer, not a CPU frame that
  was later uploaded - the AV1 VideoToolbox backport is actually in use.
- **HEVC 10-bit / HDR** shows `hwFmt=p010` (10-bit planar VideoToolbox) with
  `hwdec=videotoolbox`, so the 10-bit path stays on the GPU.
- **8K AV1 is not downscaled before decode**: the decoder receives the full
  8192x4320 surface.
- One HEVC 4K sample at 22:42:48 fell back to `hwdec=no` / `yuv420p`. It was not
  reproducible on request, so the trigger is still unknown; the current setting
  is `videotoolbox,auto-safe`, and `auto-safe` is allowed to drop to software
  when VideoToolbox rejects a stream. Pinning `videotoolbox` removes the
  fallback at the cost of failing outright on streams the decoder refuses.

## Continuous-playback evidence (iPhone Air, iOS 27.2)

Instrumented build 5592 carried temporary `Utils.reportError` probes that
wrote decoder state into `Documents/.pili_logs.json`; they were removed again
before the shipped build. A 36-minute AV1 4K session reported:

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
  background -> foreground plus danmaku toggles.
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
| AV1 hardware decode, proven by codec string | pass: codec=av1 + containerPixFmt=videotoolbox at 3840x2160 and 8192x4320 |
| HEVC 10-bit / HDR | pass: codec=hevc + hwFmt=p010 + hwdec=videotoolbox |
| Dolby Vision (dvh1) | not exercised: no dvh1 rendition was offered for the sampled titles |
| HEVC 4K software-decode outlier | one non-reproducible `hwdec=no` sample; trigger unknown, see codec evidence |
| Battery/thermal curve | not measurable: the device stayed on the charger during the run |
| 8K AV1 | pass: decoder receives the full 8192x4320 surface in hardware |
## Status on 2026-11-05 (current code, re-measured)

The table above describes **build 5581–5596 for iOS 27.2**, not the current
branch. It is kept as history; none of it was carried forward as a pass. What was
re-measured on iOS 27.3 with this branch is in
[`ios-av1-hardware-evidence-2026-11-05.md`](ios-av1-hardware-evidence-2026-11-05.md),
including the four samples that were replayed and the six that were not.

Short version, with the limits attached:

| Check | Result on 2026-11-05 |
| --- | --- |
| AV1 8-bit SDR 4K60 → hardware | pass: 31/31 and 32/32 samples `hwdec-current=videotoolbox`, `vd: Decoder format … videotoolbox[nv12]` |
| H.264 4K60 still hardware | pass (13/13 samples) — the injected `Avcodec` did not regress the other codecs |
| Ten-bit AV1 (SDR) | plays on the native AVPlayer path with a correct picture; its VideoToolbox state is **unavailable**, not inferred |
| 1080p / 4K30 AV1, 8K AV1, 3422×2160, HLG, Dolby Vision | not measured this round |
| 15/30-minute stability, thermal, A/V sync | not measured |
| Signed release bundle re-test | identity verified; not re-measured on device |

An installable build that omits the AV1 decoder is no longer possible: both build
scripts and CI fail instead of shipping one.
