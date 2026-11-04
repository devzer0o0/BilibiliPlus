import 'package:PiliPlus/plugin/pl_player/backend/playback_route.dart';
import 'package:PiliPlus/plugin/pl_player/capability.dart';
import 'package:flutter_test/flutter_test.dart';

/// A screenshot is three capabilities, not one.
///
/// The still frame (mpv texture), the native frame (AVPlayerItemVideoOutput) and
/// animated WebP (its own MpvConvertWebp encoder) fail for different reasons and
/// exist on different backends. Treating them as one is how "we fixed
/// screenshots" ended up meaning nothing on the native path.
void main() {
  group('still frame availability', () {
    test('the mpv route offers the texture capture', () {
      const caps = PlaybackCapabilities(isMpv: true, route: PlaybackRoute.mpv);
      expect(caps.screenshot, isTrue);
      expect(caps.nativeScreenshot, isFalse);
    });

    test('the native route offers the frame extractor, not the texture one', () {
      const caps = PlaybackCapabilities(
        isMpv: false,
        route: PlaybackRoute.native,
      );
      expect(caps.screenshot, isFalse);
      expect(caps.nativeScreenshot, isTrue);
    });

    test('preparing and disposed offer neither', () {
      for (final route in [PlaybackRoute.preparing, PlaybackRoute.disposed]) {
        final caps = PlaybackCapabilities(isMpv: false, route: route);
        expect(caps.screenshot, isFalse, reason: '$route');
        expect(caps.nativeScreenshot, isFalse, reason: '$route');
      }
    });
  });

  group('animated WebP is its own capability', () {
    test('it is not implied by the still frame on the native path', () {
      const native = PlaybackCapabilities(
        isMpv: false,
        route: PlaybackRoute.native,
      );
      expect(native.nativeScreenshot, isTrue);
      expect(native.animatedScreenshot, isFalse);
    });

    test('mpv can run the encoder', () {
      const mpv = PlaybackCapabilities(isMpv: true, route: PlaybackRoute.mpv);
      expect(mpv.animatedScreenshot, isTrue);
    });
  });

  test('every route states a reason instead of failing silently', () {
    const caps = PlaybackCapabilities(isMpv: false, route: PlaybackRoute.none);
    expect(caps.unsupportedReason('截图', PlaybackRoute.none), contains('尚未'));
    expect(
      caps.unsupportedReason('截图', PlaybackRoute.preparing),
      contains('准备'),
    );
  });
}
