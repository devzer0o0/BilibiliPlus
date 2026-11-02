import 'package:flutter_test/flutter_test.dart';

/// HDR correctness comes down to the HEVC profile in the codec string:
/// `hvc1.2.4` is Main10 (10-bit, needs tone mapping on an 8-bit texture) while
/// `hvc1.1.6` is Main (8-bit, safe). Verified against the live catalogue API
/// on 2026-11-03: id 125 -> hvc1.2.4, id 122/120 -> hvc1.1.6.
///
/// These helpers describe that rule; the app itself gates on literal ids.
bool isTenBitHevc(String codecs) =>
    codecs.startsWith('hev1.2') || codecs.startsWith('hvc1.2');

bool isTenBitAv1(String codecs) =>
    codecs.startsWith('av01.') && codecs.contains('.10.');

void main() {
  group('HEVC profile', () {
    test('hvc1.2.4 is 10-bit', () {
      expect(isTenBitHevc('hvc1.2.4.L153.90'), isTrue);
      expect(isTenBitHevc('hev1.2.4.L153.90'), isTrue);
    });

    test('hvc1.1.6 is 8-bit', () {
      // This is what id 122 and 120 serve; they are plain 4K.
      expect(isTenBitHevc('hvc1.1.6.L153.90'), isFalse);
      expect(isTenBitHevc('hvc1.1.6.L150.90'), isFalse);
    });

    test('the HDR rung and the 4K rung really do differ', () {
      expect(isTenBitHevc('hvc1.2.4.L153.90'), isNot(isTenBitHevc('hvc1.1.6.L153.90')));
    });
  });

  group('AV1 profile', () {
    test('av01 with profile 10 is 10-bit', () {
      expect(isTenBitAv1('av01.0.12M.10.0.110.01.01.01.0'), isTrue);
    });

    test('av01 with profile 08 is 8-bit', () {
      expect(isTenBitAv1('av01.0.12M.08.0.110.01.01.01.0'), isFalse);
    });
  });

  group('AVC is always 8-bit', () {
    test('no listed AVC profile is 10-bit', () {
      for (final c in ['avc1.640033', 'avc1.640032', 'avc1.640028']) {
        expect(isTenBitHevc(c), isFalse);
        expect(isTenBitAv1(c), isFalse);
      }
    });
  });
}