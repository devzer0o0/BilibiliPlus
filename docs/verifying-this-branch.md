# Verifying this branch

One command runs everything that can be checked without a physical device:

```sh
tool/full_regression.sh
```

| Stage | What it proves |
| --- | --- |
| unit suite | 148 tests over quality selection, HDR gating, output sizing, DRM fallback routing and layout |
| release constraints | bundle id, AV1 ABI 61.3.100, 359 exports, no diagnostic residue |
| HDR gate | asking for 125 with tone mapping off logs `picked=120`, not 125 |
| 4K exactness | asking for 120 logs `picked=120` |

Last run: all four passed.

## Individual checks

```sh
flutter test                                  # unit suite
tool/verify_release_constraints.sh <Runner.app>   # store/ABI/diagnostics
tool/hdr_pick_check.sh <bvid> <qn> <tonemap>  # one rendition case
tool/hdr_regression.sh <bvid> <qn> <tonemap>  # capture + classify frames
tool/check_player_frame.py <png...>           # black / green / ok
```

## Why the QA_PICK line matters

A frame can look correct while the player is on the wrong rendition: 360p,
1080p and HDR all pass a colour check. `QA_PICK` (debug builds only) records
`prefer` / `picked` / `codec` / `available`, which is the only trustworthy way
to tell which stream actually played. It is compiled out of release builds and
`verify_release_constraints.sh` asserts that.

## What still needs a physical device

The simulator forces `enableHardwareAcceleration = false`, so VideoToolbox
never runs. Everything below is therefore unverified here:

- 4K/8K AV1 hardware decode
- HDR arriving as `p010` on the hardware path (the original green screen)
- the native output-resize path, which requires `hwdec != null`

Those were verified earlier on an iPhone Air (see
[ios-av1-adaptation.md](ios-av1-adaptation.md)); HDR there still needs
re-checking with the tone-mapping switch on.

## Open question: PLVideoPlayer does not appear to build

While trying to confirm the output-resize path, debugPrint markers were added
to `_videoWidget` in `lib/plugin/pl_player/view/view.dart` and to
`NativeVideoSurface._attach`. The video page played normally, and `QA_PICK`
from `VideoUtils.findTargetVideo` did appear in the same log stream, but **none
of the `SURFACE_*` markers ever printed** - not even the one at the very top of
`_videoWidget`.

What was checked, and ruled out:

| Hypothesis | Check | Result |
| --- | --- | --- |
| stale build | `strings kernel_blob.bin \| grep SURFACE_BUILD` on the installed bundle | present (2 hits) |
| log capture timing | started `log stream --level debug` before relaunch | `QA_PICK` captured, markers not |
| wrong class | `grep 'class PLVideoPlayer'` across `lib/` | one class, `view/view.dart:90` |
| wrong import | `lib/pages/video/view.dart` imports `pl_player/view/view.dart` | confirmed |
| early return | read `_videoWidget` from its opening brace | no early return before the marker |

So the video page renders something other than this widget, or the getter is
never evaluated on the path that paints the surface. The temporary markers were
removed; `QA_PICK` was kept because the regression scripts rely on it.

This matters because `resizeVideoOutput` and `NativeVideoSurface` are the
code that implements the branch's headline feature. Their logic is unit tested
(`video_output_size_test.dart`, `video_output_resize_test.dart`), but whether
the widget is wired into the live player is **unverified**. Resolving it needs
either a widget test that pumps `PLVideoPlayer`, or a device build where the
resize can be observed end to end.

## Why the attached iPhone still cannot be driven from the CLI

`xcrun devicectl` exposes a lot, but not enough to run a test unattended:

| Capability | Present | Usable here |
| --- | --- | --- |
| `capture screenshot` | yes | yes - works while the screen is on |
| `process launch` | yes | **no** - needs the device unlocked |
| `remote.hid.digitizer` | advertised | **no CLI subcommand** |
| `remote.hid.button` | advertised | **no CLI subcommand** |
| `device simulate` | biometrics only | no wake/sleep |

`devicectl device --help` lists no HID subcommand, and neither `idb`
(simulators only) nor `pymobiledevice3` is installed. So an attached phone can
be screenshotted but not unlocked or tapped from this machine, which is why the
hardware checks above need a person to unlock the device once.

A locked device answers `process launch` with
`FBSOpenApplicationErrorDomain error 7 (BSErrorCodeDescription = Locked)`.