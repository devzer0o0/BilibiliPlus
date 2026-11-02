# HDR playback verification (simulator)

Date: 2026-11-03. Simulator: iPhone Air, iOS 27.2.

## What can and cannot be verified here

The simulator forces `enableHardwareAcceleration = false` (`VideoOutput.swift`),
so it exercises media_kit's software path. That is still useful: it is the
same 8-bit BGRA destination the hardware path uses, so a tone-mapping or
pixel-format mistake shows up here as black or green frames.

## Objective frame check

Do not judge by eye. Crop the player area, reduce it to one pixel with `sips`
and read the RGB value:

```sh
sips -c 560 1260 --cropOffset 210 0 frame.png --out crop.png
sips -z 1 1 -s format png crop.png --out tiny.png
```

Then classify:

| Average RGB | Meaning |
| --- | --- |
| sum < 60 | black - nothing rendered |
| G > R + 20 and G > B + 20 | green - 10-bit planes in an 8-bit texture |
| otherwise | rendering correctly |

`python3` on this machine has no PIL, so decode the 1x1 PNG with `zlib` and
a chunk walk instead of importing an imaging library.

## Results so far

Title: `BV1b24y1w73N` (`【4K/HDR】AVC/HEVC/AV1编码上传对比测试`), whose
playurl reports `ids=[125, 120, 116, 80, 64, 32, 16]` - it really does serve
the HDR ladder, unlike many titles that merely say HDR in the name.

| Stream | Tone mapping | Result |
| --- | --- | --- |
| AVC 20000kbps | off | renders normally (8-bit source) |
| HEVC 20000kbps | on | renders normally, RGB (125,122,111) |
| HEVC 20000kbps | off | one sample showed a black player area |

The single black sample was not reproduced on re-run, so it is recorded as
an observation rather than a confirmed regression. The user-facing switch
defaults to off, which restores the pre-change behaviour exactly.

## Still owed on hardware

VideoToolbox hands 10-bit frames over as `p010` rather than the software
path's 8-bit frames, so the hardware combination is the one that produced
the original green screen. Only a physical iPhone can confirm that the
tone-mapping options fix it there too.