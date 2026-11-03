import 'package:PiliPlus/pages/video/widgets/native_subtitle_overlay.dart';
import 'package:flutter_test/flutter_test.dart';

/// The native HDR path renders subtitles itself, so the cue parsing is the only
/// thing standing between bilibili's JSON and a visible line. It is asserted
/// here rather than eyeballed.
void main() {
  test('parses the body bilibili returns', () {
    const body =
        '[{"from":1.5,"to":3.0,"content":"第一句"},'
        '{"from":4.0,"to":6.0,"content":"第二句"}]';
    final cues = parseNativeSubtitle(body);
    expect(cues, hasLength(2));
    expect(cues.first.from, 1.5);
    expect(cues.first.to, 3.0);
    expect(cues.first.text, '第一句');
  });

  test('sorts by start time', () {
    const body =
        '[{"from":9.0,"to":10.0,"content":"later"},'
        '{"from":1.0,"to":2.0,"content":"earlier"}]';
    final cues = parseNativeSubtitle(body);
    expect(cues.map((c) => c.text), ['earlier', 'later']);
  });

  test('drops entries that cannot be drawn', () {
    const body =
        '[{"from":1.0,"to":2.0,"content":""},'
        '{"from":3.0,"content":"no end"},'
        '{"from":5.0,"to":6.0,"content":"ok"}]';
    final cues = parseNativeSubtitle(body);
    expect(cues.map((c) => c.text), ['ok']);
  });

  test('a malformed body yields no cues instead of throwing', () {
    expect(parseNativeSubtitle('{}'), isEmpty);
  });
}
