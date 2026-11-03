import 'package:PiliPlus/pages/video/widgets/native_subtitle_overlay.dart';
import 'package:flutter_test/flutter_test.dart';

/// The native HDR path paints its own subtitles. This is the rule that decides
/// whether a line is on screen at a given moment - the only part a viewer can
/// actually judge - so it is asserted rather than eyeballed.
void main() {
  final cues = <({double from, double to, String text})>[
    (from: 1.0, to: 3.0, text: '第一句'),
    (from: 3.0, to: 5.0, text: '第二句'),
    (from: 10.0, to: 12.0, text: '第十秒'),
  ];

  test('nothing shows before the first cue', () {
    expect(subtitleTextAt(cues, 0.5), '');
  });

  test('the covering cue shows', () {
    expect(subtitleTextAt(cues, 2.0), '第一句');
  });

  test('it disappears after the cue ends', () {
    expect(subtitleTextAt(cues, 6.0), '');
  });

  test('gaps between cues show nothing', () {
    expect(subtitleTextAt(cues, 7.5), '');
  });

  test('a boundary belongs to the cue that starts there', () {
    // 3.0 is the end of the first and the start of the second; the later one
    // wins because the scan takes the first match in start order.
    expect(subtitleTextAt(cues, 3.0), '第一句');
  });

  test('an empty list never shows anything', () {
    expect(subtitleTextAt(const [], 5.0), '');
  });
}
