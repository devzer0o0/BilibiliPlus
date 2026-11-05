# AV1 hardware decoding on iPhone Air — evidence, 2026-11-05

This file records what was measured, on which build, on which device. It replaces
inference with observation wherever that was possible, and names what could not be
observed.

## 1. Environment (measured, not assumed)

| Item | Value | How |
| --- | --- | --- |
| Device | iPhone Air (iPhone18,4), UDID `00008150-001E5C592E78401C` | `xcrun devicectl device info details` |
| OS | iOS 27.3 (24C5037i) | same |
| Source | branch `feature/4k-output-size`, HEAD `28e5673e8` + this task's diff (dirty tree) | `git rev-parse HEAD` |
| Build | profile, `--dart-define=PILIPLUS_DIAGNOSTICS=true`, signed with team `8TQDS9JT23` | `tool/identity.sh` |
| Flutter | 3.47.9 (revision c197ca5199) | `tool/identity.sh` |
| Xcode / SDK | 27.2 / iphoneos 27.2 | same |
| mpv | 0.39.0 (`libmpv`, `vo=libmpv`, `ios-gl` enabled, `videotoolbox-gl` disabled) | `strings Mpv.framework/Mpv` |
| FFmpeg | libavcodec 61.3.100 (FFmpeg 7.0.2 ABI) + AV1 VideoToolbox backport | `otool -L`, `nm` |
| Loaded Avcodec | UUID `7B672380-F2DC-3D5C-B40B-2A1CF0720FA0`, `av1_videotoolbox` present, 359 exports, deps unchanged | `tool/ios_av1_package.sh verify` |
| Stock pod Avcodec | UUID `821154CD-1BEF-348D-B064-FD4F98B30B10`, **no** `av1_videotoolbox` | same tool, negative case |

The app bundle contains exactly one `Avcodec` binary, so the UUID above is the
library the process links (`Runner` and `Mpv` both reference
`@rpath/Avcodec.framework/Avcodec`, and `Runner` carries
`@executable_path/Frameworks` as an rpath).

## 2. What mpv was asked for, and what it did

Read back from the running player after `VideoController.create` had written its
own values (`mpv-hwdec` record):

```
requested=videotoolbox enableHA=true hardwareDecoding=videotoolbox \
applied=videotoolbox hwdec-codecs=all vo=libmpv
```

That line exists because the request is not the result. `hwdec` is what mpv was
asked for; `hwdec-current` is what it chose.

## 3. AV1 8-bit SDR on the target device — hardware confirmed

Measured with `tool/decoder_measure.sh`, which launches the installed app,
copies its diagnostics file off the device while playback runs, and parses the
samples the player wrote. All runs: quality pinned to 120 (4K), mpv route.

| Title | Rendition | Samples | Hardware | Software | Decoder format reported by libmpv |
| --- | --- | --- | --- | --- | --- |
| BV1C8xn6YEDA | 3840x2160 60.0 fps `av01.0.13M.08` | 31 | 31 | 0 | `3840x2160 videotoolbox[nv12] bt.709/bt.709/bt.1886/limited/auto` |
| BV1Epx967EY2 | 4096x2160 59.994 fps `av01.0.13M.08` | 32 | 32 | 0 | `videotoolbox[nv12]` |
| BV1Epx967EY2 (earlier run) | 4096x2160 59.994 fps | 33 | 33 | 0 | `videotoolbox[nv12]` |
| BV1nynq68Ess (earlier run) | 3840x2024 59.932 fps | 32 | 32 | 0 | `videotoolbox[nv12]` |

The first two rows were taken on the final build (the one carrying the capability
model); the last two on the same code minus that model. Both builds injected the
same `Avcodec` UUID, so they describe the same decoder.

`videotoolbox[nv12]` in `vd: Decoder format` is the decoded frame format: the
frame mpv receives **is** the VideoToolbox `CVPixelBuffer`, not a CPU frame that
was uploaded afterwards. Together with `hwdec-current=videotoolbox` on 103 of 103
samples, that is the hardware evidence — not the `hwdec=` request, and not a
symbol in the binary.

Reproduce one of them:

```sh
bash tool/decoder_measure.sh BV1C8xn6YEDA 70
# RESULT=AV1_HARDWARE_CONFIRMED
```

## 4. The failure that was reproduced first

Before the injection was made mandatory, a build produced by a plain
`flutter build ios` shipped the pod's `Avcodec`. On 2026-11-05 between 14:50 and
14:57 that build played a 3840x2160 60 fps AV1 stream and reported:

```
460 of 460 decoder samples: hwdec=no format=av1 src=3840x2160 fps=60.0 totalDrops=2872 (cumulative)
```

That is the failure: a working AV1 VideoToolbox path on the chip, a build that did
not contain it, and an app that reported AV1 as available because it asked the
chip rather than the library. The fix is the build and capability changes below;
the decoder itself did not need a new FFmpeg for 8-bit SDR.

## 5. Ten-bit AV1 (SDR) — native path, picture verified, hardware not directly readable

`BV1P661YyESp` at quality 120 serves `av01.0.00M.10` (ten-bit, SDR). The player
routes ten-bit renditions to AVPlayerLayer, so this is a different renderer:

- `route useNative=true ... codecs=av01.0.00M.10...`, `native-open`,
  `backend-open createSession-ok`;
- three screenshots 3 s apart differ, and the frame shows the expected picture
  with danmaku composited (no green cast, no black frame);
- AVPlayer owns its `VTDecompressionSession` privately. `UsingHardwareAcceleratedVideoDecoder`
  cannot be read for it, and mpv's properties do not describe it. **Recorded as
  unavailable**, not inferred.

Colour handling changed with this task: a ten-bit stream whose `colr` box is
missing is no longer declared PQ merely because it is ten-bit. `VIDEO-RANGE` now
comes from the Dolby sample entry or from an HDR quality rung (125/126/129), and
stays unknown otherwise. `ios/RunnerTests/ColorRangeTests.swift` pins that rule,
including the exact ten-bit SDR AV1 codec string above.

## 6. Not verified in this round

| Item | Status | Why |
| --- | --- | --- |
| AV1 8-bit 1080p / 4K30 | not measured | every run pinned quality 120 (4K60); the 1080p rung was not exercised |
| AV1 10-bit HDR10/PQ, HLG | not measured | no HLG sample available; PQ rungs on the sampled titles are HEVC/Dolby |
| AV1 8K | not measured | no 8K title identified this round |
| 3422x2160 AV1 | not measured | the size appears in earlier device samples, not replayed against this build |
| Dolby Vision regression | not exercised | no `dvh1`/profile-5 title sampled this round |
| AVPlayer hardware decode | unavailable | AVFoundation exposes no equivalent of `hwdec-current` |
| 15/30-minute stability, thermal, A/V sync | not measured | requires an instrumented session; `tool/decoder_measure.sh` reports duration-limited samples only |
| Final signed release build retest | see delivery note | the measurements above are a profile diagnostic build; the release bundle is verified by identity, not re-measured |

## 7. What changed so the same failure cannot recur silently

- `tool/ios_av1_package.sh` — one implementation of "put the right Avcodec in the
  bundle and prove it", shared by both build scripts and CI. It compares the
  Mach-O UUID, the **full** exported symbol set and the dependent libraries, and
  fails the build when the bundle would ship the pod's binary.
- `tool/ios_build.sh` no longer prints `SKIPPED` and installs anyway; a missing
  decoder, a missing identity or a failed re-sign is `BLOCKED_AV1`.
- `tool/verify_release_constraints.sh` uses that same check instead of a
  whole-file hash (which can never match after re-signing) and a hardcoded "359".
- `lib/plugin/pl_player/models/av1_capability.dart` separates four states:
  system, media library, backend, session. Only an established "the loaded
  library has no AV1 VideoToolbox decoder" demotes AV1; an unanswered probe does
  not.
Measured on the target device, the capability record reads:

```
av1-system  VTIsHardwareDecodeSupported(av1)=true
av1-probe   available=true av1VT=true lib=61.3.100
            hwConfigs=[{deviceType: videotoolbox, pixFmt: videotoolbox_vld, methods: 11}]
codec-capability Av1Capability(system=supported library=supported backend=unknown session=idle lib=61.3.100)
```

One detail there cost a build: `av_get_pix_fmt("videotoolbox")` and the hw
config's `pix_fmt` are the same format under two names (`videotoolbox` and
`videotoolbox_vld`), so comparing the enum values reported "no AV1 VideoToolbox
hwaccel" for a library that plainly has one — and that wrong answer demoted AV1 on
a device that decodes it in hardware.

- `lib/plugin/pl_player/utils/av1_capability_probe.dart` asks the **loaded**
  FFmpeg through `dlsym`: `avcodec_version`, `avcodec_configuration`,
  `avcodec_find_decoder_by_name("av1")` and `avcodec_get_hw_config` (first three
  fields only), so no second copy of FFmpeg and no header set is introduced.
- `HwDecType.resolveHwdec` — turning hardware decoding off now sends `no`
  instead of a null that media_kit rewrites to `auto`.
