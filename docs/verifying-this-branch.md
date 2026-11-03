# Verifying this branch

For the overall picture - what changed, what is proven, and what is explicitly
not - see [branch-status.md](branch-status.md).

One command runs everything that can be checked without a physical device:

```sh
tool/full_regression.sh
```

| Stage | What it proves |
| --- | --- |
| script self-checks | the verification scripts themselves fail on bad input and on unscannable bundles |
| unit suite | 158 tests over quality selection, HDR gating, output sizing, DRM fallback routing and layout |
| release constraints | bundle id, AV1 ABI 61.3.100, 359 exports, no diagnostic residue |
| experiment scaffolding | `VPARAM`, `TEMP_FORCE_HDR`, `TEMP_NO_TONEMAP`, `SURFACE_`, `PLVP_` absent from the AOT binary |
| HDR gate | asking for 125 with tone mapping off logs `picked=120`, not 125 |
| 4K exactness | asking for 120 logs `picked=120` |

Last run: all six passed.

Three deliberate strictnesses were added after each caused real trouble:

- the release stage **fails** when no release build exists, instead of printing
  SKIP. A green run that checked nothing is worse than a red one.
- the scaffolding scan exists because debug markers were left in the tree more
  than once during this session and only caught by hand.
- `tool/selftest.sh` asserts the scripts' own failure paths, because two of them
  exited 0 on a misinvocation. Writing it found two *more* scripts still exiting
  1, which a hand-fix pass had missed.

That last point is the pattern worth keeping: fixing checks by hand did not
converge, and asserting them did.

## Individual checks

```sh
flutter test                                  # unit suite
tool/verify_release_constraints.sh <Runner.app>   # store/ABI/diagnostics
tool/hdr_pick_check.sh <bvid> <qn> <tonemap>  # one rendition case
tool/playback_check.sh <bvid> <qn> <tone> <auto>  # real playback + frame diff
tool/hdr_regression.sh <bvid> <qn> <tonemap>  # capture + classify frames
tool/check_player_frame.py <png...>           # black / green / ok
```

## HDR actually plays, and the gate is what protects it

Measured with `tool/playback_check.sh BV1b24y1w73N 125 <tonemap> 1`:

| Tone mapping | Logged pick | Frames | Reading |
| --- | --- | --- | --- |
| on | `picked=125 codec=HEVC` | 3 distinct, RGB ok, HUD showed FPS 49 | 10-bit HDR decoded and rendered correctly |
| off | `picked=120 codec=AVC` | 3 distinct, RGB ok | the gate refused to fetch 125 at all |

The important part is the second row. With the switch off, 125 is never
requested - `Pref.defaultVideoQa` becomes 127, the server returns the ladder, and
`_findAvailableVideoQuality` settles on 120. So the green screen cannot occur
because **the 10-bit stream never plays**; it is not being rendered wrongly.

```text
playback: QA_PICK prefer=125 picked=125 codec=HEVC
frames:   f0 e5d15911  f1 df22ad6a  f2 634dc4a7   (all different = playing)
colour:   RGB(41,30,17) RGB(71,55,33)  -> ok, not green
```

### The green screen cannot be reproduced in the simulator at all

A debug-only escape hatch (`PILIPLUS_FORCE_HDR_NO_TONEMAP`) was added to let
125 through with tone mapping **off**, to force the original bug. The result
was not green:

```text
QA_PICK prefer=125 picked=125 codec=HEVC    <- 10-bit stream, gate bypassed
frames: 6a34acdb / 5d13bb26 / 19fbe2b9      <- playing
colour: RGB(36,27,15) .. RGB(72,55,33)      <- correct, HUD showed FPS 49
```

So the defect is **specific to the VideoToolbox path**, not to feeding 10-bit
frames into the 8-bit texture in general. The software renderer converts colour
itself; VideoToolbox hands over `p010` without doing so. That matches what the
original investigation concluded, and it means:

- the simulator cannot be used to prove the tone-mapping fix works
- it also cannot be used to reproduce the bug
- the only way to settle either question is a physical device

The escape hatch was removed after the experiment.

### Measured: mpv hands over 8-bit either way

Rather than infer this from the picture, the player was instrumented to read
mpv's own `video-params/*` properties 8 seconds into playback:

| Run | `pixelformat` | `primaries` | `gamma` | source |
| --- | --- | --- | --- | --- |
| 125 HDR, tone-mapping options **injected** | `yuv420p` | `bt.709` | `bt.1886` | 1920x1080 |
| 127 requested, gate picks 120 (SDR) | `nv12` | `bt.709` | `bt.1886` | 1080x1920 |
| 125 HDR, tone-mapping options **suppressed** | `yuv420p` | `bt.709` | `bt.1886` | 2160x2880 |

All three come out 8-bit SDR with a BT.709 / BT.1886 output.

**The third row is the important one**: with
`tone-mapping`/`hdr-compute-peak`/`target-colorspace-hint` deliberately *not*
passed, mpv still produced `yuv420p` / `bt.709` / `bt.1886`. So on the software
path those options make no measurable difference - mpv converts on its own.

That weakens a claim made earlier in this document. The tone-mapping options are
not what saves the software path; the software path was never at risk. Whether
they help on the **hardware** path, where VideoToolbox hands over `p010`, is
untested and cannot be tested here.

The probe was removed after the measurement, and so was the temporary
`TEMP_FORCE_HDR`/`TEMP_NO_TONEMAP` scaffolding.

## The failure panel was checked on screen

When playurl fails the player area used to render nothing, leaving only a
two-second toast. It now shows the reason over a dimmed cover with a retry
button.

Reaching that state normally needs a video that actually fails, and neither
`simctl openurl` nor `idb open` can deliver a link to the app here: the bundle
declares no `associated-domains` entitlement and no entitlements file at all, so
iOS hands every https URL to Safari. Driving the UI to a dead video is not
possible either.

So it was checked with a temporary launch hook
(`--dart-define=TEMP_SHOW_PLAY_ERROR`) that pushed `/videoV` with a dead bvid
after six seconds. On screen:

```text
视频不存在或已被删除
      [ 重试 ]
```

with the info panel, comments and UP block loading normally around it - i.e. the
failure is confined to the player area, which is the intent.

Two mistakes were made getting there, both in the hook rather than the product:
omitting `videoType` produced a Null-not-a-subtype-of-VideoType crash, and
omitting `heroTag` produced the same for String. The page asserts those
arguments, so a wrong hook fails loudly instead of rendering something
plausible.

The hook was removed afterwards; `lib/pages/main/view.dart` is unchanged.

## The quality sheet was checked on screen

After fixing the blank rows, the sheet was opened in the simulator against a
real title:

```text
选择画质
1080P 高码率      (current)
1080P 高清        flv
720P 准高清       flv720
480P 标清         flv480
360P 流畅         mp4
```

Every row reads as something; before the fix a run of rows after these was
completely empty.

### Reaching the controls at all

Taps in the middle of the player do not reveal the control bar: `_onTapUp`
routes them to the danmaku layer when a bullet comment sits under the finger,
so the centre of the screen is effectively reserved. Tapping the **top-right
corner** (about 390,130 on a 420 pt wide screen) shows the controls reliably.
This is upstream behaviour, not a regression.

### One thing deliberately left alone

The sheet expands to the full available height, so a five-row ladder leaves a
large empty area below it. Constraining it to the content height was attempted
and reverted: the call goes through `MiniScaffold.showBottomSheet`, whose
builder takes a single argument and whose shape is shared with three other
sheets. Changing that shared signature to close a cosmetic gap was not worth the
blast radius. Recorded so the next person does not rediscover it.

## Physical-device check (iPhone Air, iOS 27.2)

For most of this branch's life the attached iPhone reported `Locked` and
`devicectl` refused to launch anything. Once unlocked the following worked, and
the first real hardware playback evidence was obtained.

### Installing at all

`flutter build ios --release --no-codesign` produces a bundle that
`devicectl device install app` rejects with `ApplicationVerificationFailed`.
The project sets `DEVELOPMENT_TEAM = ""`, but a valid
`Apple Development: ...` identity is present, so a plain
`flutter build ios --release` lets Xcode pick it and the install succeeds.

Debug builds install but refuse to start from the home screen:

> In iOS 14+, debug mode Flutter apps can only be launched from Flutter
> tooling, IDEs with Flutter plugins or from Xcode.

and `devicectl` counts as none of those. Profile and release run normally.

### Getting a video on screen without touching the phone

`idb` is simulator-only. `devicectl device process launch` has `--payload-url`,
which hands a URL to the app at launch:

```sh
xcrun devicectl device process launch --device <udid> \
  --payload-url https://www.bilibili.com/video/BV1b24y1w73N \
  com.example.pilipalax
```

That opens the video page directly - the deep-link path that cannot work in the
simulator, because here the URL is passed to the process rather than routed by
the system.

### Result: 4K/HDR plays on hardware without a green screen

Title BV1b24y1w73N (a 4K/HDR AVC/HEVC/AV1 comparison upload), profile build,
tone-mapping switch **off** so the gate is closed:

```text
player-area hashes:  8829e3e1 / 7cb1ea4e / 7f844bf1   (all different = playing)
colour samples:      RGB(114,38,22)  RGB(69,41,70)    -> ok, not green
```

Consecutive frames differ, so this is playback and not a poster, and the
colours are normal. With the gate closed the ladder settles on an SDR rung, so
this confirms the gate behaves on hardware - it does **not** yet confirm that
the tone-mapped 10-bit path renders correctly.

### Still not answered

Whether 125/126/129 render correctly through VideoToolbox with tone mapping
**on**. That needs the switch toggled on the device, and there is no CLI path
to change an app preference on a physical iPhone: `devicectl` has no file push,
`idb` will not attach, and the accessibility tree is unreachable. The options
are to drive the UI by hand, or to ship a build whose default is pre-set.

## Why the QA_PICK line matters

A frame can look correct while the player is on the wrong rendition: 360p,
1080p and HDR all pass a colour check. `QA_PICK` (debug builds only) records
`prefer` / `picked` / `codec` / `available`, which is the only trustworthy way
to tell which stream actually played. It is compiled out of release builds and
`verify_release_constraints.sh` asserts that.

## What still needs a physical device

The simulator forces `enableHardwareAcceleration = false`, so VideoToolbox
never runs. Unverified here:

- 4K/8K AV1 hardware decode
- HDR arriving as `p010` on the hardware path (the original green screen)

Those were verified earlier on an iPhone Air (see
[ios-av1-adaptation.md](ios-av1-adaptation.md)); HDR there still needs
re-checking with the tone-mapping switch on.

## Output resize: verified in the simulator

Auto-play must be on for any of this to run (see below). With
`SEED_AUTOPLAY=1`, instrumenting `NativeVideoSurface` showed the resize
actually happening:

```text
SURF rect = Rect.fromLTRB(0.0, 0.0, 0.0, 0.0)          <- before the first frame
SURF rect = Rect.fromLTRB(0.0, 0.0, 1080.0, 1920.0)    <- source size
SURF SETSIZE 1001x1779                                 <- request sent to native
SURF rect = Rect.fromLTRB(0.0, 0.0, 1001.0, 1779.0)    <- native confirmed
```

The 1080x1920 source became a 1001x1779 buffer. That matches the fit maths: the
portrait player is about 333.7 pt wide, so the contain ratio is
`333.7 * 3 / 1080 = 0.9269`, and `1080 * 0.9269 = 1001`.

So the path is wired and does apply a resize - it simply never executed in the
earlier runs because playback had not started. `hwdec` is non-null whenever
`Pref.enableHA` is true (the default), which is what the gate requires.

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

A second round narrowed it down. `PLVideoPlayer.build` was instrumented directly
and a counter was added to the `Obx` in `plPlayer()`:

```text
PLVP_GATE calls: 1
   PLVP_GATE hit=1 state=false autoPlay=false hasCtrl=false
PLVP_BUILD: 0
QA_PICK: 1
```

So the gate **is** evaluated - exactly once, while all three conditions are
still false - and the `Obx` never rebuilds afterwards. That is why the player
widget is never constructed even though playback works.

## Resolved: auto-play was off, so nothing ever initialised

The explanation is mundane. `Pref.autoPlayEnable` defaults to **false**:

```dart
static bool get autoPlayEnable =>
    _setting.get(SettingBoxKey.autoPlayEnable, defaultValue: false);
```

With auto-play off, `initPlayerIfNeeded` returns `null` without calling
`playerInit`, so `setDataSource` never runs, `onInit` never fires,
`videoState` stays false, and the `Obx` in `plPlayer()` correctly renders
`SizedBox.shrink()`. The video page shows the **cover image**, not a paused
frame - which is what three earlier rounds mistook for playback.

The tell is that consecutive screenshots of the player area were byte-identical:

```text
frame 0: ff183e2ff165bf76
frame 1: ff183e2ff165bf76      <- cover, not video
frame 2: ff183e2ff165bf76
```

With `SEED_AUTOPLAY=1` the same check gives three different hashes and the
widget tree builds normally.

Lessons worth keeping:

- "the screen shows the video" is not evidence of playback; compare successive
  frames of the player rect.
- every earlier marker (`PLVP_GATE`, `SURFACE_BRANCH`, `SETDS`, `ONINIT`) was
  correct to stay silent - the code genuinely was not running.

`tool/tests/seed_account_test.dart` gained `SEED_AUTOPLAY` so playback scenarios
can be set up headlessly. Temporary markers were removed; `QA_PICK` was kept
because the regression scripts rely on it.

The output-resize wiring is therefore **not** broken - it simply never executed
in the earlier runs because playback never started. Its logic remains covered by
`video_output_size_test.dart` and `video_output_resize_test.dart`.

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