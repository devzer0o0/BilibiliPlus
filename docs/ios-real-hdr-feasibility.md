# Real HDR on iOS: feasibility findings

Question: can PiliPlus show the same HDR effect as the official bilibili app,
rather than a 4K SDR picture?

Answer so far: **the stream is real HDR and AVFoundation reads it correctly, but
Flutter's texture path cannot display it.** A different rendering path is needed.

## The stream is genuine HDR10

Fetched `BV1b24y1w73N` at `qn=125` and assembled the init segment plus the first
media segment into a playable clip, then asked AVFoundation what it is:

```text
codec                hev1  (HEVC Main10)
ColorPrimaries       ITU_R_2020          (BT.2020)
TransferFunction     SMPTE_ST_2084_PQ    (HDR10 / PQ)
MasteringDisplayColorVolume   present
ContentLightLevelInfo         present
Duration             5.0 s, 1 video track
```

So the catalogue really does serve PQ/BT.2020, and the system's own media stack
identifies it as HDR rather than falling back to SDR.

## Why the current player cannot show it

`media_kit_video`'s iOS texture creates every buffer as
`kCVPixelFormatType_32BGRA` (see `OpenGLESHelpers.createPixelBuffer` and
`TextureSWContext`). Flutter's `FlutterTexture.h` documents only three formats,
all 8-bit:

- `kCVPixelFormatType_32BGRA`
- `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`
- `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`

The Flutter iOS engine contains no `wantsExtendedDynamicRangeContent` selector
and no 10-bit pixel format string at all, so an external texture cannot carry an
extended-range signal no matter what is fed into it. 8-bit BGRA is a hard ceiling:
the picture is tone-mapped down before it ever reaches the compositor.

That is why "no green screen, correct colours" was the right description but the
wrong conclusion - the tone mapping is doing its job, and doing it means
discarding the HDR.

## What real HDR would require

An `AVPlayerLayer`, which is the only public iOS surface that composites
extended-range video:

```swift
let layer = AVPlayerLayer(player: player)
layer.wantsExtendedDynamicRangeContent = true   // iOS 17+
```

This is a different rendering path from mpv's texture, not a setting on it. It
means:

- a native overlay (or platform view) hosting `AVPlayerLayer`, positioned over
  the Flutter surface, shown only when the selected rendition is 10-bit HDR;
- mpv keeps handling everything it is good at (SDR playback, danmaku, subtitles,
  the quality ladder), and HDR playback is handed to AVPlayer;
- audio stays with mpv, or is delegated too - a decision to make during design.

Feasibility is therefore **confirmed for the source and the platform**, and the
work is real: it is a second playback engine, not a patch.

## What was checked and thrown away

A temporary `HdrProbePlugin` (an `AVPlayerLayer` fed the real stream) and a
screenshot-based read-out were built and run on the device. `AVPlayerItem`
reported `ready = true` and `wantsExtendedDynamicRangeContent = true` was
accepted, but `presentationSize` came back `0x0` for the bare DASH segment,
which is why the metadata was read on the host instead of on the phone. All of
that scaffolding was removed; `lib/` and `ios/` are unchanged.
