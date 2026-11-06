import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// Dolby Vision sample entries come in two spellings, and the level field
/// varies: `dvh1.05.09` and `dvh1.05.10` are the same profile at different
/// levels. Anything keyed on an exact string silently stops matching.
///
/// The real failure here was narrower and worse than "unsupported":
/// `dvhe.08.10` matched no format at all and `fromString` threw
/// "Bad state: No element" while the video was opening.
void main() {
  group('both Dolby sample entries resolve', () {
    test('dvh1 and dvhe are the same format', () {
      expect(
        VideoDecodeFormatType.fromString('dvh1.05.10'),
        VideoDecodeFormatType.DVH1,
      );
      expect(
        VideoDecodeFormatType.fromString('dvhe.08.10'),
        VideoDecodeFormatType.DVH1,
      );
    });

    test('the level does not affect the profile', () {
      expect(VideoUtils.dolbyVisionProfileOf('dvh1.05.10'), 5);
      expect(VideoUtils.dolbyVisionProfileOf('dvh1.05.09'), 5);
      expect(VideoUtils.dolbyVisionProfileOf('dvh1.08.10'), 8);
    });

    test('every level is ten-bit', () {
      for (final c in [
        'dvh1.05.06',
        'dvh1.05.10',
        'dvhe.07.06',
        'dvhe.08.10',
      ]) {
        expect(VideoUtils.isTenBitCodec(c), isTrue, reason: c);
      }
    });
  });

  group('an unknown codec degrades instead of throwing', () {
    test('fromString does not raise on an unrecognised entry', () {
      // This runs while opening a video and while building the quality list; a
      // throw takes the screen down.
      expect(
        () => VideoDecodeFormatType.fromString('vp09.00.10.08'),
        returnsNormally,
      );
    });

    test('the fallback is a real format, not a null', () {
      final format = VideoDecodeFormatType.fromString('vp09.00.10.08');
      expect(VideoDecodeFormatType.values, contains(format));
    });
  });

  group('labels are readable', () {
    test('Dolby is spelled out rather than shown as a four-character code', () {
      expect(VideoDecodeFormatType.DVH1.description, contains('杜比'));
    });
  });
}
