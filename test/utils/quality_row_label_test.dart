import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// The quality sheet lists every format the catalogue declares and greys out
/// the ones that are not actually available, so the user can see that a higher
/// rung exists. Those entries can have a null `newDesc`, and the row used
/// `newDesc!` - a blank line in debug and a crash in release.
void main() {
  group('a row always has a label', () {
    test('a described format uses its description', () {
      expect(VideoUtils.qualityRowLabel(80, 'flv', 'x'), 'flv');
    });

    test('an undescribed format falls back to the quality id', () {
      // 122 shows up in real ladders without a VideoQuality entry.
      final label = VideoUtils.qualityRowLabel(122, null, '暂不支持');
      expect(label, isNotEmpty);
      expect(label, isNot('暂不支持'));
    });

    test('the unsupported marker only replaces an empty label', () {
      expect(VideoUtils.qualityRowLabel(122, null, '暂不支持'), isNot('暂不支持'));
    });
  });

  group('the sheet shows unavailable rungs but disables them', () {
    test('an unavailable rung is not selectable', () {
      const ladder = {120, 116, 80};
      expect(VideoUtils.isQualitySelectable(125, ladder), isFalse);
      expect(VideoUtils.isQualitySelectable(120, ladder), isTrue);
    });
  });
}