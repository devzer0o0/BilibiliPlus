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
## Why the native HDR path needed a one-byte fix

The AVPlayerLayer path fetched the DASH track correctly and requested EDR, yet
`AVPlayerItem` never reached `readyToPlay`: `isPlayable` was false,
`presentationSize` stayed `0x0` and the format descriptions carried no colour
metadata.

The track's sample entry is `hev1`. **AVFoundation will not play `hev1`** - only
`hvc1`. The bitstream is identical; the difference is where the parameter sets
sit, and `hvcC` carries them for both, so rewriting the fourcc is sufficient.

Measured on the assembled clip, before and after that single change:

```text
before:  isPlayable=false   transfer=nil                 primaries=nil
after:   isPlayable=true    transfer=SMPTE_ST_2084_PQ    primaries=ITU_R_2020   bits=10
```

### A second bug in the same function

`describe()` read its colour metadata from the keys `"TransferFunction"` and
`"ColorPrimaries"`. Those keys exist in the extension dictionary but are empty;
the real values are under `"CVImageBufferTransferFunction"` and
`"CVImageBufferColorPrimaries"`. That is why `hdr` read false even for a stream
that is genuinely PQ/BT.2020 - the same symptom as the fourcc bug, from a
completely different cause, which is what made this take two rounds to find.

Both are now correct and the predicate keys off `CVImageBufferTransferFunction`
containing `2084` (PQ) or `HLG`.

### Confirmed in the simulator after the fix

The earlier claim that the simulator cannot decode 10-bit HEVC was wrong - it
was the `hev1` sample entry all along. With the fourcc rewritten, the lab page
reports:

```text
hdr=true  edr=true  ready=true
xfer=SMPTE_ST_2084_PQ  prim=ITU_R_2020  3840x2160  src=assembled-4194304
```

So AVPlayerItem reaches readyToPlay, the layer has EDR requested, and the
track reports PQ / BT.2020 at 4K. The native path is wired correctly.

### Still unverified

The picture itself, for two reasons:

1. The plugin fetches only a 4 MB prefix, which is roughly a second of 4K, so
   there is little to see and nothing to scrub. Full playback needs the whole
   segment list, not a prefix.
2. Whether the panel actually shows extended range - visibly brighter highlights
   - cannot be judged from a screenshot, which is tone-mapped to 8-bit on the
   way out. EDR requested plus PQ metadata is the strongest programmatic
   evidence available; the visual claim needs a device in a dark room.

Audio is not connected either: only the video track is fetched.

## Where this ended up

The native path is now the one the app actually uses for 10-bit renditions, and
most of what was open above has since been closed or explained.

### Verified on the simulator

| Capability | Evidence |
| --- | --- |
| Reaches the native path from a real page | deep link into a video page, `hdr=true` |
| PQ / BT.2020 / 3840x2160 | `xfer=SMPTE_ST_2084_PQ prim=ITU_R_2020` |
| Picture renders | layer frame follows the view; picture appears |
| Plays through a whole part | 43s, 63s, 76s, 97s checkpoints all advancing |
| Audio | `audio=playing-...` alongside the video |
| Pause and resume | clock held at 15.753s for ten seconds, then resumed |
| Seek | 13.8s -> 60.0s in one step, then continued |
| Progress reaches the controls | position and duration written back each poll |
| Danmaku scrolls | `BV1C8xn6YEDA` (HDR + dense comments): rows moving over a live 4K frame |

### The bugs that made this take as long as it did

1. `hev1` vs `hvc1`. AVFoundation refuses the former; one fourcc swap fixed
   `isPlayable` and the colour metadata.
2. Wrong extension keys. `TransferFunction` is empty; the value lives under
   `CVImageBufferTransferFunction`. This produced the same false "no HDR"
   symptom from an unrelated cause.
3. `sidx` offsets. `version` was read at the type field, so `count` came out
   as 21764 and every fragment range was wrong.
4. A layer frame set once at zero. CALayer sublayers do not follow their
   superlayer, so nothing was drawn until `layoutSubviews` drove it.
5. Rx writes during build. `onReady` wrote three observables inside the Obx
   that owns the surface, recreating the platform view mid-assembly.

### Two measurements that lied

- Three identical screenshot crops read as "the picture is frozen". The crop was
  of a static band; the clock was advancing the whole time.
- Text over the picture read as danmaku. It was the video's own FPS overlay -
  the test title is a quality comparison that films one.

Both were fixed by watching a written log instead of a screenshot, and by
picking a title whose content cannot be mistaken for UI.

### Still not proven

- **Subtitles on this path.** The renderer exists and is unit tested, but no
  tried title both selects the native path and ships a subtitle track:
  `BV1b24y1w73N` has none and `BV1C8xn6YEDA` has none either.
- **Visible extended range.** A screenshot is tone-mapped to 8-bit on the way
  out, so EDR requested plus PQ metadata is as far as evidence goes; the
  brightness claim needs a panel in front of a person.

### A note on durations

`x/web-interface/view` reports `duration` as the sum of a multi-part video's
pages, not the length of the page being played. Reading it as one video's length
made a 98-second part look like a truncated 392-second film and sent two rounds
after a "97 second cap" that did not exist.
