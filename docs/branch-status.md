# Branch status report

Generated at the end of an extended autonomous run. Every claim below is
backed by either a test, a log line, or a screenshot recorded in this repo's
docs. Anything unverified is listed as such rather than implied to work.

## Scope

iOS only, targeting iPhone Air (iPhone18,4). Bundle id unchanged at
`com.example.pilipalax`. The vendored AV1 VideoToolbox framework keeps ABI
61.3.100 and its 359 exports.

| Metric | Value |
| --- | --- |
| commits on branch | 51 |
| lib files changed | 16 (+466 / -97) |
| test files | 24 |
| tests | 148, all passing |

## Functional changes

### 1. HDR is gated, and the gate is layered

`125/126/129` are 10-bit HLG/PQ. Blocking them was the first fix; the gate now
has three layers:

1. `VideoUtils.unsupportedVideoQualities` - literal id blocklist
2. `VideoUtils.isTenBitCodec` - codec profile (`hvc1.2.4` / `av01 ... .10.`),
   which catches a future 10-bit rung shipped under a new id
3. `VideoUtils.selectVideoVariant` - refuses a 10-bit variant even when it is
   the first entry for a quality id

Behind all of it is `HdrSupport`, whose `nativeTenBitPath` is `false` because
Flutter's iOS external texture accepts only `32BGRA` and two 8-bit biplanar
formats - there is no 10-bit entry in `FlutterTexture.h`.

### 2. Every quality picker honours the gate

The in-player sheet, the default-quality dialog, the cellular dialog and the
download panel all filter through the same predicate. Before this, the
settings dialogs still offered HDR, so a stored HDR default would bring the
problem back on every later video.

### 3. Tone mapping is a user switch

`设置 -> 音视频设置 -> HDR 色调映射` toggles `tone-mapping=auto`,
`hdr-compute-peak=yes`, `target-colorspace-hint=yes`. The mpv options are only
injected when the gate is open, so SDR playback pays nothing.

Verified in the simulator: switch off -> ladder ends at 4K, 125 is never
fetched (`picked=120`); switch on -> `picked=125 codec=HEVC` plays with three
distinct frames and correct colour.

### 4. Bottom safe area no longer counted twice

`MainLayout` pins the nav bar to the edge and `NavigationBar` applies its own
`SafeArea`, but the wrapper only removed the top inset. Measured: the
destination row sat at `bottom=878` on a 912 pt screen. Now 912. Re-checked
on iPhone 18 Pro (402x874): also flush, six tabs with zero out-of-bounds.

### 5. Hardware-decoding list is platform-filtered

The dialog enumerated every mpv backend, so iPhone users scrolled past
DirectX/VAAPI/CUDA to reach `videotoolbox`. `HwDecType.valuesForPlatform` cuts
the iOS list to six rows.

### 6. DRM catalogue fallback

`/ogv/player/playview` for the primary request, `/pgc/player/web/v2/playurl`
for the retry when `arc.is_drm` is set. Both envelope shapes are asserted in
`test/models/pgc_envelope_test.dart`.

## Verification

`tool/full_regression.sh` runs the three stages together and exits non-zero on
failure: unit suite, release constraints, simulator HDR gate. Last run: all
passed.

CI gained a `flutter test` step - the repository previously built without ever
running the tests.

## What is verified, and how

| Claim | Evidence |
| --- | --- |
| quality selection matrix | `video_quality_gate_matrix_test.dart`, 9 cases |
| HDR gate at every rung | simulator runs, `QA_PICK` log lines |
| 10-bit detection | live API codec strings, `hevc_bit_depth_test.dart` |
| output resize applies | `rect 1080x1920 -> SetSize 1001x1779 -> confirmed` |
| resize debounce | `video_output_resize_test.dart`, 7 cases |
| layout at two sizes | 420x912 and 402x874, zero out-of-bounds |
| release constraints | bundle id, ABI 61.3.100, 359 exports, no markers |

## What is NOT verified

These need a physical iPhone. The simulator forces
`enableHardwareAcceleration = false`, so VideoToolbox never runs:

1. **4K/8K AV1 hardware decode.** Was observed earlier on an iPhone Air
   (`codec=av1 containerPixFmt=videotoolbox`, `src=8192x4320`), but not
   re-checked since the HDR changes.
2. **HDR through VideoToolbox (`p010`).** This is the original green-screen
   bug. Proven not reproducible in the simulator: a debug escape hatch forced
   125 through with tone mapping off and it still rendered correctly, because
   the software renderer converts colour itself and VideoToolbox does not.

Consequence: the tone-mapping fix is logically sound and verified to be wired,
but whether it cures the hardware green screen is **unproven**.

## Known caveats

- `122` appears in catalogue ladders with no `VideoQuality` entry. It is
  `hvc1.1.6` (8-bit) so it is safe, and `fromCode` degrades to showing the raw
  number. A future *10-bit* id would need adding to the blocklist.
- Dolby Vision (`dvh1`) was never observed in any sampled title, so its
  handling is untested beyond the id gate.
- Auto-play defaults to off. Any playback measurement must set
  `SEED_AUTOPLAY=1` or it will silently measure a cover image - this tripped
  up several rounds before being diagnosed.