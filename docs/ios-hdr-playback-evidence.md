# HDR / Dolby Vision playback evidence

Date: 2026-11-03. Simulator: iPhone Air, iOS 27.2, debug build.

## Why three earlier runs proved nothing

`tool/hdr_regression.sh` initially classified frames only by average colour.
A 360P capture, an HDR capture and a Dolby Vision capture all reported
`RGB=(150,135,107) -> ok`, which looked like three successes but was in fact
the same 1080P stream every time.

Two things hid the mistake:

1. The player reads `Pref.defaultVideoQaCellular` when the connection is
   metered, and the simulator reports a metered connection. Pinning only
   `defaultVideoQa` (the Wi-Fi slot) had no effect.
2. Frame colour cannot distinguish resolutions. It only detects black
   (nothing rendered) and green (10-bit planes in an 8-bit texture).

The seeder now writes both slots, and `findTargetVideo` logs the decision in
debug builds:

```text
QA_PICK prefer=126 picked=126 codec=HEVC available=[126, 112, 112, 112, 80, ...]
```

## Evidence

Title `BV1Hbs96JEM3` (single-part, `accept_quality` includes 126).

| Tone mapping | Logged pick | Frame | Reading |
| --- | --- | --- | --- |
| on | `prefer=126 picked=126 codec=HEVC` | ok | Dolby Vision selected and rendered |
| off | `prefer=126 picked=112 codec=AV1` | ok | gate refused 126, fell back to an SDR rendition |
| on, Wi-Fi slot only | `prefer=80 picked=80 codec=AV1` | ok | the bug this section documents |

The off case is the important control: asking for Dolby Vision with tone
mapping disabled does not play it, it degrades to an SDR stream. That is the
behaviour the gate is meant to have.

## Reproduce

```sh
bash tool/hdr_regression.sh BV1Hbs96JEM3 126 1   # tone mapping on
bash tool/hdr_regression.sh BV1Hbs96JEM3 126 0   # tone mapping off
```

Read `QA_PICK` from the simulator log to confirm which rendition was chosen;
do not infer it from the picture.

## Limit

The simulator forces the software path, so this shows the 8-bit destination
handling 10-bit streams correctly. VideoToolbox hands frames over as `p010`
on hardware, and that specific combination still needs a physical iPhone.