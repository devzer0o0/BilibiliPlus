import 'package:PiliPlus/models/common/video/base_quality.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/video/play/url.dart' show VideoItem, FormatItem;
import 'package:PiliPlus/plugin/pl_player/models/selected_rendition.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// dvh1.05.10 is profile 5, level 10 - the same profile as .05.09 but a higher
/// level (bigger pictures / higher bitrate). Anything keyed on the exact string
/// "dvh1.05.09" silently stops matching it.
void main() {
  test('level 10 is accepted wherever level 9 is', () {
    for (final codec in ['dvh1.05.09', 'dvh1.05.10', 'dvh1.08.10']) {
      expect(VideoUtils.isTenBitCodec(codec), isTrue, reason: codec);
      expect(VideoUtils.dolbyVisionProfileOf(codec), isNotNull, reason: codec);
      expect(
        VideoDecodeFormatType.fromString(codec),
        VideoDecodeFormatType.DVH1,
        reason: codec,
      );
    }
  });

  test('the profile is parsed independently of the level', () {
    expect(VideoUtils.dolbyVisionProfileOf('dvh1.05.10'), 5);
    expect(VideoUtils.dolbyVisionProfileOf('dvh1.08.10'), 8);
    expect(VideoUtils.dolbyVisionProfileOf('dvhe.07.10'), 7);
  });

  test('a level-10 rung is not downgraded', () {
    final chosen = VideoUtils.selectRendition(
      videoList: [
        VideoItem(
          id: 126,
          codecs: 'dvh1.05.10',
          width: 3840,
          height: 2160,
          baseUrl: 'https://cdn.example/a.m4s',
          quality: VideoQuality.fromCode(126),
        ),
      ],
      supportFormats: [
        FormatItem(quality: 126, codecs: ['dvh1.05.10']),
      ],
      preferCodecs: const [VideoDecodeFormatType.HEVC],
      preferQuality: 126,
      allowTenBit: true,
      allowHdrRungs: true,
    );
    expect(
      chosen.fallback?.reason,
      isNot(RenditionFallbackReason.dolbyVisionUnsupportedProfile),
    );
  });
}
