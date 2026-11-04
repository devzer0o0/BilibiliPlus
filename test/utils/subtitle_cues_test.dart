import 'package:PiliPlus/plugin/pl_player/models/subtitle_cue.dart';
import 'package:flutter_test/flutter_test.dart';

/// The subtitle contract is one typed list. This fixture is the shape the
/// service returns (a `body` array of `from`/`to`/`content` objects), not a
/// hand-built VTT, so the parse the app actually performs is the one asserted.
void main() {
  const response =
      '{"body":['
      // Escaped in Dart so the JSON sees \n, the way the service sends it.
      '{"from":0.0,"to":2.5,"content":"第一行\\n第二行"},'
      '{"from":3.0,"to":4.2,"content":"带 emoji 😀 与 CJK"},'
      '{"from":9.0,"to":9.0,"content":"瞬间"},'
      '{"from":12.0,"to":13.0,"content":"  "},'
      '{"from":15.0,"to":14.0,"content":"倒序时间"},'
      '{"from":20.0,"to":21.0}'
      ']}';

  test('parses the service body into cues', () {
    final cues = parseSubtitleCues(response);
    expect(cues.map((c) => c.text), [
      '第一行\n第二行',
      '带 emoji 😀 与 CJK',
      '瞬间',
      '  ',
    ]);
  });

  test('keeps multi-line and unicode text intact', () {
    final cues = parseSubtitleCues(response);
    expect(cues.first.text.contains('\n'), isTrue);
    expect(cues[1].text.contains('😀'), isTrue);
    expect(cues[1].text.contains('CJK'), isTrue);
  });

  test('drops an entry with no end time and one that ends before it starts', () {
    final cues = parseSubtitleCues(response);
    expect(cues.any((c) => c.to == 21.0), isFalse);
    expect(cues.any((c) => c.text == '倒序时间'), isFalse);
    expect(cues.every((c) => c.to >= c.from), isTrue);
  });

  test('malformed bodies yield an empty list', () {
    for (final body in ['', '{', 'null', '{"body":[]}', '"vtt"']) {
      expect(parseSubtitleCues(body), isEmpty, reason: body);
    }
  });

  test('the covering cue is found at the exact boundaries', () {
    final cues = parseSubtitleCues(response);
    expect(subtitleTextAt(cues, 0.0), '第一行\n第二行');
    expect(subtitleTextAt(cues, 2.5), '第一行\n第二行');
    expect(subtitleTextAt(cues, 2.6), '');
    expect(subtitleTextAt(cues, 9.0), '瞬间');
    expect(subtitleTextAt(cues, 21.0), '');
  });
}
