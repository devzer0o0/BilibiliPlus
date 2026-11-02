import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// When playurl fails the player area used to render nothing, so the failure
/// was only visible in a two-second toast. The panel decision is a pure
/// function so it can be asserted without mounting the page.
void main() {
  group('the failure panel only appears when there is something to say', () {
    test('an empty message renders nothing', () {
      expect(VideoUtils.showsPlayErrorPanel(''), isFalse);
      expect(VideoUtils.showsPlayErrorPanel(null), isFalse);
    });

    test('whitespace alone is not a message', () {
      expect(VideoUtils.showsPlayErrorPanel('   '), isFalse);
      expect(VideoUtils.showsPlayErrorPanel('\n\t'), isFalse);
    });

    test('a real message shows the panel', () {
      expect(VideoUtils.showsPlayErrorPanel('视频不存在或已被删除'), isTrue);
    });
  });

  group('the message the panel shows comes from the error path', () {
    // Ties the panel to parseVideoErr, so the panel cannot start showing
    // something the rest of the error path has stopped producing.
    const codes = <int?>[-404, 87008, -10403, -999, null];
    for (final code in codes) {
      test('code $code yields a displayable message', () {
        final msg = VideoHttp.parseVideoErr(code, 'detail');
        expect(VideoUtils.showsPlayErrorPanel(msg), isTrue);
      });
    }
  });
}