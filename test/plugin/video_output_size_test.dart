import 'package:PiliPlus/plugin/pl_player/utils/video_output_size.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// `videoOutputSize` decides the pixel buffer mpv renders into. Sizing that
/// buffer to the source instead of the viewport is what makes 4K output feel
/// heavy, so the fit maths is worth pinning down.
void main() {
  // iPhone Air: 420x912 pt at DPR 3 -> 1260x2736 physical pixels.
  const viewportPortrait = Size(420, 350);
  const dpr = 3.0;

  group('contain fit', () {
    test('a 16:9 source is limited by the viewport width', () {
      // 3840x2160 into a 420x350 viewport: width binds at 420, height 236.25.
      final size = videoOutputSize(
        source: const Size(3840, 2160),
        viewport: viewportPortrait,
        devicePixelRatio: dpr,
        fit: BoxFit.contain,
      );
      expect(size, isNotNull);
      // ratio = 420 / (3840/3) = 0.328125
      expect(size!.width, (3840 * 0.328125).ceilToDouble());
      expect(size.height, (2160 * 0.328125).ceilToDouble());
    });

    test('aspect ratio is preserved', () {
      final size = videoOutputSize(
        source: const Size(3840, 2160),
        viewport: viewportPortrait,
        devicePixelRatio: dpr,
        fit: BoxFit.contain,
      )!;
      expect(size.width / size.height, closeTo(16 / 9, 0.01));
    });

    test('the output never exceeds the source resolution', () {
      // A small viewport must not upscale past the source.
      final size = videoOutputSize(
        source: const Size(1920, 1080),
        viewport: const Size(2000, 2000),
        devicePixelRatio: 1,
        fit: BoxFit.contain,
      )!;
      expect(size.width, lessThanOrEqualTo(1920));
      expect(size.height, lessThanOrEqualTo(1080));
    });
  });

  group('cover fit', () {
    test('uses the cropped region so the buffer fills the viewport', () {
      final size = videoOutputSize(
        source: const Size(3840, 2160),
        viewport: const Size(420, 420),
        devicePixelRatio: dpr,
        fit: BoxFit.cover,
      )!;
      // Cover crops horizontally; the result must still be within the source.
      expect(size.width, lessThanOrEqualTo(3840));
      expect(size.height, lessThanOrEqualTo(2160));
      expect(size.width, greaterThan(0));
    });
  });

  group('scale', () {
    test('doubling the scale doubles the buffer, capped at the source', () {
      final base = videoOutputSize(
        source: const Size(3840, 2160),
        viewport: viewportPortrait,
        devicePixelRatio: dpr,
        fit: BoxFit.contain,
      )!;
      final doubled = videoOutputSize(
        source: const Size(3840, 2160),
        viewport: viewportPortrait,
        devicePixelRatio: dpr,
        fit: BoxFit.contain,
        scale: 2,
      )!;
      expect(doubled.width, closeTo(base.width * 2, 2));
      expect(doubled.width, lessThanOrEqualTo(3840));
    });
  });

  group('invalid input', () {
    test('an empty source yields null instead of throwing', () {
      expect(
        videoOutputSize(
          source: Size.zero,
          viewport: viewportPortrait,
          devicePixelRatio: dpr,
          fit: BoxFit.contain,
        ),
        isNull,
      );
    });

    test('an empty viewport yields null', () {
      expect(
        videoOutputSize(
          source: const Size(3840, 2160),
          viewport: Size.zero,
          devicePixelRatio: dpr,
          fit: BoxFit.contain,
        ),
        isNull,
      );
    });

    test('a non-finite source yields null', () {
      expect(
        videoOutputSize(
          source: const Size(double.infinity, 2160),
          viewport: viewportPortrait,
          devicePixelRatio: dpr,
          fit: BoxFit.contain,
        ),
        isNull,
      );
    });

    test('a zero device pixel ratio yields null', () {
      expect(
        videoOutputSize(
          source: const Size(3840, 2160),
          viewport: viewportPortrait,
          devicePixelRatio: 0,
          fit: BoxFit.contain,
        ),
        isNull,
      );
    });

    test('a zero scale yields null', () {
      expect(
        videoOutputSize(
          source: const Size(3840, 2160),
          viewport: viewportPortrait,
          devicePixelRatio: dpr,
          fit: BoxFit.contain,
          scale: 0,
        ),
        isNull,
      );
    });
  });

  group('aspect ratio override', () {
    // Documented behaviour: mpv keeps the SOURCE aspect ratio and Flutter does
    // the fitting. The override only changes how large a buffer is needed.
    test('the buffer keeps the source aspect ratio', () {
      final size = videoOutputSize(
        source: const Size(1920, 1080),
        viewport: const Size(420, 600),
        devicePixelRatio: 1,
        fit: BoxFit.contain,
        aspectRatio: 4 / 3,
      )!;
      expect(size.width / size.height, closeTo(16 / 9, 0.02));
    });

    // Measured on a 420x600 viewport with a 1920x1080 source:
    //   4:3   -> 560x315   (taller display ratio needs more pixels)
    //   16:9  -> 420x237
    //   21:9  -> 320x180   (wider display ratio needs fewer)
    test('a taller display ratio needs a larger buffer', () {
      Size? at(double? ratio) => videoOutputSize(
        source: const Size(1920, 1080),
        viewport: const Size(420, 600),
        devicePixelRatio: 1,
        fit: BoxFit.contain,
        aspectRatio: ratio,
      );
      expect(at(4 / 3)!.width, greaterThan(at(16 / 9)!.width));
      expect(at(21 / 9)!.width, lessThan(at(16 / 9)!.width));
    });

    test('the buffer never exceeds the source', () {
      final size = videoOutputSize(
        source: const Size(1920, 1080),
        viewport: const Size(5000, 5000),
        devicePixelRatio: 1,
        fit: BoxFit.contain,
        aspectRatio: 4 / 3,
      )!;
      expect(size.width, lessThanOrEqualTo(1920));
      expect(size.height, lessThanOrEqualTo(1080));
    });
  });
}