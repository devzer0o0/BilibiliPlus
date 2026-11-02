# Where quality is chosen, and which paths the HDR gate covers

Found by enumerating rather than by memory - an earlier round missed the
control-bar popup by only checking the settings dialogs.

| # | Surface | File | Gated by |
| --- | --- | --- | --- |
| 1 | in-player quality sheet | `pages/video/widgets/header_control.dart` | `isQualitySelectable` + re-check in `onTap` |
| 2 | control-bar quality popup | `plugin/pl_player/view/view.dart` (`BottomControlType.qa`) | `isQualitySelectable` + re-check in `onTap` |
| 3 | default-quality dialog | `pages/setting/models/video_settings.dart` | `isSupportedVideoQuality` filter |
| 4 | cellular-quality dialog | same file | same filter |
| 5 | download panel picker | `pages/video/download_panel/view.dart` | `isSupportedVideoQuality` filter |
| 6 | download request | `http/download.dart` | inherits `findTargetVideo` |
| 7 | animated screenshot picker | `plugin/pl_player/view/view.dart` (动态截图) | **deliberately not gated** - see below |

## Surfaces 1-6

All of these end up persisting a choice or requesting a stream through the
player's 8-bit texture path, so a 10-bit rung would either turn the screen
green or become a sticky default. They all consult
`VideoUtils.isQualitySelectable` / `isSupportedVideoQuality`, which is where a
future 10-bit rung gets caught (see `isTenBitCodec`).

## Surface 7 is intentionally exempt

动态截图 transcodes a clip to animated WebP through mpv:

```dart
'ovc': 'libwebp_anim',
if (enableHA) 'vo': 'gpu',
if (enableHA) 'hwdec': '${Pref.hardwareDecoding},auto-copy',
```

`auto-copy` pulls hardware-decoded frames back to CPU memory and mpv does the
colour conversion before handing them to libwebp. The frames never reach
Flutter's 8-bit texture, so 10-bit input is not the failure mode here and
blocking it would only remove a working option.

Confidence: this is read from the option list, **not** from an actual 10-bit
transcode. The dialog needs manual interaction and sits behind a screenshot
button, so it was not exercised. The risk of being wrong is low and bounded -
the worst case is a failed export, not a green screen - but it is an assumption
rather than a measurement.

If this picker ever starts feeding the live texture instead of the transcoder,
it must be gated like the others.

## Keeping this list honest

To re-derive it:

```sh
grep -rn 'VideoQuality.values\|videoFormat.length\|supportFormats' lib/ \
  --include=*.dart | grep -v 'models/' | grep -v grpc/
grep -rn 'defaultVideoQa' lib/ --include=*.dart
grep -rn 'BottomControlType' lib/plugin/pl_player/
```

The third command is what surfaced surface 2.