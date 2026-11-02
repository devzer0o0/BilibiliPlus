import 'package:PiliPlus/http/video.dart';
import 'package:flutter_test/flutter_test.dart';

/// These strings are shown verbatim to the user when playback fails, so they
/// are worth asserting: a stray brace or a swallowed message is invisible in
/// code review but obvious on screen.
void main() {
  group('known failure codes', () {
    test('-404 reads as a deleted video, ignoring the server message', () {
      expect(VideoHttp.parseVideoErr(-404, '啥都木有'), '视频不存在或已被删除');
    });

    test('87008 keeps the server message without a stray brace', () {
      final text = VideoHttp.parseVideoErr(87008, '充电专属');
      expect(text, contains('充电专属'));
      // The template used to be "($msg})", which rendered a literal '}'.
      expect(text, isNot(contains('})')));
      expect(text, endsWith(')'));
    });

    test('a null message does not render the word null', () {
      final text = VideoHttp.parseVideoErr(87008, null);
      expect(text, isNot(contains('null')));
      expect(text, endsWith(')'));
    });

    test('-10403 explains the DRM case', () {
      expect(
        VideoHttp.parseVideoErr(-10403, 'copyright'),
        '该内容受版权保护，当前无法播放',
      );
    });
  });

  group('unknown codes', () {
    test('the code and message are both surfaced', () {
      expect(VideoHttp.parseVideoErr(-999, 'boom'), contains('-999'));
      expect(VideoHttp.parseVideoErr(-999, 'boom'), contains('boom'));
    });

    test('a null code still produces readable text', () {
      expect(() => VideoHttp.parseVideoErr(null, null), returnsNormally);
    });
  });
}