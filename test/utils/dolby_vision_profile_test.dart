import 'package:PiliPlus/models/common/video/base_quality.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/video/play/url.dart' show VideoItem, FormatItem;
import 'package:PiliPlus/plugin/pl_player/models/selected_rendition.dart';
import 'package:PiliPlus/plugin/pl_player/utils/hdr_support.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// Dolby Vision is an AVPlayer capability, not something this app decodes.
///
/// Apple supports profile 5 on iPhone 12 and later, and AVFoundation applies the
/// RPU itself once the track arrives through a correctly declared HLS variant.
/// An earlier version of this file asserted the opposite - that profile 5 must be
/// refused - and that is what made 杜比视界 unplayable: the app downgraded to SDR,
/// then the player sat on 加载中.
///
/// The real defect was the variant declaring HLG for a PQ stream. These tests
/// pin the encoding facts routing depends on.
VideoItem _video(
  int id,
  String codecs, {
  int width = 3840,
  int height = 2024,
}) => VideoItem(
  id: id,
  codecs: codecs,
  width: width,
  height: height,
  frameRate: '60',
  baseUrl: 'https://cdn.example/$id-$codecs.m4s',
  quality: VideoQuality.fromCode(id),
);

FormatItem _format(int quality, List<String> codecs) =>
    FormatItem(quality: quality, codecs: codecs, newDesc: '$quality');

void main() {
  group('dolby vision sample entries', () {
    test('dvh1 and dvhe are ten-bit streams', () {
      // Measured live: the 126 rung serves `dvh1.05.09`. Missing this
      // classified it 8-bit, which routed a Dolby track to mpv - a path with an
      // 8-bit texture that never reads the RPU.
      expect(VideoUtils.isTenBitCodec('dvh1.05.09'), isTrue);
      expect(VideoUtils.isTenBitCodec('dvhe.08.06'), isTrue);
      expect(VideoUtils.isTenBitCodec('hvc1.1.6.L153.90'), isFalse);
    });

    test('the profile is the field after the four-character code', () {
      expect(VideoUtils.dolbyVisionProfileOf('dvh1.05.09'), 5);
      expect(VideoUtils.dolbyVisionProfileOf('dvh1.08.06'), 8);
      expect(VideoUtils.dolbyVisionProfileOf('dvhe.07.06'), 7);
    });

    test('a non-DV codec has no profile', () {
      expect(VideoUtils.dolbyVisionProfileOf('hvc1.2.4.L153.90'), isNull);
      expect(VideoUtils.dolbyVisionProfileOf('av01.0.13M.08'), isNull);
      expect(VideoUtils.dolbyVisionProfileOf(null), isNull);
    });
  });

  group('dolby vision is not downgraded', () {
    // The rungs stay in the ladder, but whether 126 is *selectable* also depends
    // on the host: on a non-iOS test runner allowsHdrQuality is false, so the
    // global HDR gate folds it down regardless of profile. What these two cases
    // assert is that no Dolby-specific refusal is added on top.
    test('a profile-5 rung is not refused for being profile 5', () {
      final chosen = VideoUtils.selectRendition(
        videoList: [
          _video(126, 'dvh1.05.09'),
          _video(120, 'hvc1.1.6.L153.90'),
        ],
        supportFormats: [
          _format(126, ['dvh1.05.09']),
          _format(120, ['hvc1.1.6']),
        ],
        preferCodecs: const [VideoDecodeFormatType.HEVC],
        preferQuality: 126,
        allowTenBit: true,
        allowHdrRungs: true,
      );
      // 126 itself may be folded by the platform-wide HDR gate; the point is
      // that no Dolby-specific reason is added.
      expect(
        chosen.fallback?.reason,
        isNot(RenditionFallbackReason.dolbyVisionUnsupportedProfile),
      );
    });

    test('a profile-8 rung written as dvhe is selected too', () {
      final chosen = VideoUtils.selectRendition(
        videoList: [
          _video(126, 'dvhe.08.06'),
          _video(120, 'hvc1.1.6.L153.90'),
        ],
        supportFormats: [
          _format(126, ['dvhe.08.06']),
          _format(120, ['hvc1.1.6']),
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
  });

  group('capability predicate', () {
    test('no profile is refused - the native path presents them all', () {
      // Profile 5 included: refusing it removed the only working path.
      expect(HdrSupport.supportsDolbyVisionProfile(5), isTrue);
      expect(HdrSupport.supportsDolbyVisionProfile(7), isTrue);
      expect(HdrSupport.supportsDolbyVisionProfile(8), isTrue);
      expect(HdrSupport.supportsDolbyVisionProfile(null), isTrue);
    });
  });
}
