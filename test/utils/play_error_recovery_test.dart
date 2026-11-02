import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// The retry button clears the error before re-fetching, so the fetch must
/// always put something back. A thrown request used to leave the field empty,
/// which made the panel vanish and returned the user to a blank rectangle.
///
/// The contract is captured here rather than by driving the controller, which
/// needs network, Hive and a live player to construct.
void main() {
  group('a failure always leaves a displayable message', () {
    test('a thrown request falls back to the generic text', () {
      final msg = VideoUtils.playErrorMessage(parsedMessage: null, threw: true);
      expect(msg, VideoUtils.playErrorOnException);
      expect(VideoUtils.showsPlayErrorPanel(msg), isTrue);
    });

    test('a throw ignores any stale parsed message', () {
      expect(
        VideoUtils.playErrorMessage(parsedMessage: '旧消息', threw: true),
        VideoUtils.playErrorOnException,
      );
    });

    test('a parsed Error keeps its own wording', () {
      final parsed = VideoHttp.parseVideoErr(-404, '啥都木有');
      expect(
        VideoUtils.playErrorMessage(parsedMessage: parsed, threw: false),
        parsed,
      );
    });

    test('an empty or whitespace parsed message still falls back', () {
      for (final bad in ['', '   ', null]) {
        expect(
          VideoUtils.playErrorMessage(parsedMessage: bad, threw: false),
          VideoUtils.playErrorOnException,
          reason: 'parsed=$bad',
        );
      }
    });
  });

  group('every branch is visible to the panel', () {
    test('no combination yields a hidden panel', () {
      for (final threw in [true, false]) {
        for (final parsed in <String?>[null, '', '  ', '视频不存在或已被删除']) {
          final msg = VideoUtils.playErrorMessage(
            parsedMessage: parsed,
            threw: threw,
          );
          expect(
            VideoUtils.showsPlayErrorPanel(msg),
            isTrue,
            reason: 'threw=$threw parsed=$parsed',
          );
        }
      }
    });
  });
}