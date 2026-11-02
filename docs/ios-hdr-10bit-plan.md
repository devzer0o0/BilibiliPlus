# HDR / 10-bit rendering plan (iOS)

Date: 2026-11-03. Device target: iPhone Air (iPhone18,4), iOS 27.2.

## Why HDR currently renders green

Bilibili's HDR ladder is `125` (HDR 真彩 / HLG), `126` (杜比视界) and `129`
(HDR Vivid). All three are HEVC Main10 and reach the player as 10-bit
`p010` after VideoToolbox.

media_kit's Darwin video output can only hand an 8-bit buffer to Flutter:

| Path | File | Format |
| --- | --- | --- |
| hardware (VideoToolbox) | `media_kit_video/ios/.../gles/OpenGLESHelpers.swift` | `CVPixelFormatType_32BGRA` |
| software | `media_kit_video/common/darwin/.../TextureSWContext.swift` | `CVPixelFormatType_32BGRA` |
| software render request | `media_kit_video/common/darwin/.../TextureSW.swift` | asks mpv for `bgr0` |

So a 10-bit frame is reinterpreted as 8-bit BGRA with no tone mapping, and
the YUV->RGB matrix is applied to the wrong planes. The result is the green
full-screen playback users report.

## The hard constraint

`FlutterTexture.h` in the shipped engine lists exactly three accepted
pixel formats:

```text
- kCVPixelFormatType_32BGRA
- kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
- kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
```

There is no 10-bit entry (`x420`, `p010`, `420YpCbCr10`) and no extended
dynamic range surface on iOS. **A true 10-bit texture cannot be delivered to
Flutter on iOS today**, no matter what media_kit does internally.

## What is achievable

### Layer 1 — tone-mapped SDR (implemented, behind a flag)

mpv/libplacebo converts HDR to BT.709 SDR before the frame reaches the 8-bit
texture. `PlPlayerController._initPlayer` now always sets:

```text
tone-mapping=auto
hdr-compute-peak=yes
target-colorspace-hint=yes
```

This is the only correct option while the texture is 8-bit. Cost: one
full-range conversion per frame, and the picture is SDR-brightness, not true
HDR. Enabled by `HdrSupport.enableToneMappedHdr`.

### Layer 2 — true 10-bit (blocked by the engine)

Would require media_kit to emit `p010` plus a Flutter engine change to accept
10-bit IOSurfaces. Neither is available:

- Flutter iOS external textures: 3 formats, none 10-bit (see above).
- `FlutterView` has no `wantsExtendedDynamicRangeContent` on iOS.

This is the same wall hardware-decode HDR hits in every Flutter video app on
iOS; it is an engine limitation, not a PiliPlus or media_kit bug.

## Decision

`HdrSupport` gates the HDR qualities (125/126/129):

| Flag | Meaning |
| --- | --- |
| `nativeTenBitPath` | false until Flutter accepts 10-bit IOSurfaces |
| `enableToneMappedHdr` | opt-in: allow HDR via layer 1 |
| `allowsHdrQuality` | derived; controls whether 125/126/129 are offered |

Default is OFF, so the quality ladder only offers the SDR renditions and the
green-screen regression cannot come back. Flipping `enableToneMappedHdr` to
true re-enables HDR with tone mapping once the layered behaviour is verified
on device.

## Verification still owed

- Layer 1 on a physical device with a real HDR title (the simulator forces the
  software renderer and cannot exercise VideoToolbox).
- Dolby Vision specifically: dynamic metadata is not handled by
  `tone-mapping=auto`; DV may still need to stay blocked even after layer 1.