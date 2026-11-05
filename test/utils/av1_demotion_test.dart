import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// AV1 on a build without the VideoToolbox backport decodes on the CPU.
///
/// Measured on device: 71 of 71 samples reported `hwdec=no format=av1` for a
/// 3422x2160 stream. The preference order still put AV1 first, so the player
/// kept choosing the one codec it could not accelerate.
///
/// The rule under test: when AV1 has no hardware decoder, the next codec in the
/// order wins; AV1 is still playable when it is the only thing offered.
void main() {
  const order = <VideoDecodeFormatType>[
    VideoDecodeFormatType.DVH1,
    VideoDecodeFormatType.AV1,
    VideoDecodeFormatType.HEVC,
    VideoDecodeFormatType.AVC,
  ];

  tearDown(() => VideoUtils.setAv1HardwareAvailable(true));

  group('with an AV1 hardware decoder', () {
    test('AV1 is preferred over HEVC', () {
      VideoUtils.setAv1HardwareAvailable(true);
      expect(
        VideoUtils.selectCodec(
          ['av01.0.13M.08', 'hvc1.2.4.L153.90'],
          order,
        ),
        VideoDecodeFormatType.AV1,
      );
    });
  });

  group('without one', () {
    setUp(() => VideoUtils.setAv1HardwareAvailable(false));

    test('HEVC is chosen when both are offered', () {
      expect(
        VideoUtils.selectCodec(
          ['av01.0.13M.08', 'hvc1.2.4.L153.90'],
          order,
        ),
        VideoDecodeFormatType.HEVC,
      );
    });

    test('AVC is the next rung when HEVC is absent', () {
      expect(
        VideoUtils.selectCodec(['av01.0.13M.08', 'avc1.640034'], order),
        VideoDecodeFormatType.AVC,
      );
    });

    test('AV1 still plays when it is the only thing offered', () {
      // A software decode beats no picture; this is a demotion, not a refusal.
      expect(
        VideoUtils.selectCodec(['av01.0.13M.08'], order),
        VideoDecodeFormatType.AV1,
      );
    });

    test('a Dolby stream is unaffected', () {
      expect(
        VideoUtils.selectCodec(['dvh1.05.10', 'av01.0.13M.08'], order),
        VideoDecodeFormatType.DVH1,
      );
    });

    test('demotion does not recurse when AV1 is the only preference', () {
      // The demoted list would be empty here; the guard must fall through to the
      // normal path instead of calling itself again.
      expect(
        () => VideoUtils.selectCodec(
          ['av01.0.13M.08'],
          const [VideoDecodeFormatType.AV1],
        ),
        returnsNormally,
      );
    });
  });
}
