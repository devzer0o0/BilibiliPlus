import 'package:PiliPlus/models/common/video/base_quality.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/video/play/url.dart' show VideoItem, FormatItem;
import 'package:PiliPlus/plugin/pl_player/models/selected_rendition.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// Selection is where "4K" is decided, so it is tested against the production
/// function with the shapes the catalogue actually serves.
///
/// The rules under test: resolution is never silently dropped when a playable
/// stream at that resolution exists, a codec fallback keeps the resolution, and
/// an HDR rung is not entered on a path that cannot present it.

VideoItem _video(
  int id,
  String codecs, {
  int width = 3840,
  int height = 2160,
  String? frameRate = '60',
}) => VideoItem(
  id: id,
  codecs: codecs,
  width: width,
  height: height,
  frameRate: frameRate,
  baseUrl: 'https://cdn.example/$id-$codecs.m4s',
  quality: VideoQuality.fromCode(id),
);

FormatItem _format(int quality, List<String> codecs) =>
    FormatItem(quality: quality, codecs: codecs, newDesc: '$quality');

void main() {
  group('resolution is preserved across codec fallback', () {
    test('AV1 preferred, HEVC served when AV1 is absent', () {
      final chosen = VideoUtils.selectRendition(
        videoList: [_video(120, 'hvc1.1.6.L153.90')],
        supportFormats: [_format(120, ['avc1.640033', 'hvc1.1.6'])],
        preferCodecs: const [VideoDecodeFormatType.AV1, VideoDecodeFormatType.HEVC],
        preferQuality: 120,
        allowTenBit: false,
        allowHdrRungs: false,
      );
      expect(chosen.video.id, 120);
      expect(chosen.width, 3840);
      // The codec preference was resolved against what the format actually
      // offers, so nothing is reported as a fallback: HEVC *is* the preference
      // that survived, and the resolution never moved.
      expect(chosen.decode, VideoDecodeFormatType.HEVC);
      expect(chosen.isExact, isTrue);
    });

    test('a 4K request is not silently answered with 1080P', () {
      final chosen = VideoUtils.selectRendition(
        videoList: [
          _video(120, 'hvc1.1.6.L153.90'),
          _video(80, 'hvc1.1.6.L120.90', width: 1920, height: 1080),
        ],
        supportFormats: [
          _format(120, ['hvc1.1.6']),
          _format(80, ['hvc1.1.6']),
        ],
        preferCodecs: const [VideoDecodeFormatType.HEVC],
        preferQuality: 120,
        allowTenBit: false,
        allowHdrRungs: false,
      );
      expect(chosen.video.id, 120);
      expect(chosen.fallback, isNull, reason: 'the exact rung was available');
    });
  });

  group('HDR is not entered on a path that cannot present it', () {
    test('an HDR rung degrades to the same resolution SDR when gated', () {
      final chosen = VideoUtils.selectRendition(
        videoList: [
          _video(125, 'hvc1.2.4.L153.B0', width: 3840, height: 2160),
          _video(120, 'hvc1.1.6.L153.90', width: 3840, height: 2160),
        ],
        supportFormats: [
          _format(125, ['hvc1.2.4']),
          _format(120, ['hvc1.1.6']),
        ],
        preferCodecs: const [VideoDecodeFormatType.HEVC],
        preferQuality: 125,
        allowTenBit: true,
        allowHdrRungs: false,
      );
      expect(chosen.video.id, 120);
      expect(chosen.fallback?.reason, RenditionFallbackReason.hdrNotPresentable);
      expect(chosen.fallback?.keptResolution, isTrue);
      expect(chosen.fallback?.message, contains('同分辨率'));
    });

    test('10-bit is not taken when the path cannot carry it', () {
      final chosen = VideoUtils.selectRendition(
        videoList: [
          _video(125, 'hvc1.2.4.L153.B0'),
          _video(120, 'hvc1.1.6.L153.90'),
        ],
        supportFormats: [
          _format(125, ['hvc1.2.4']),
          _format(120, ['hvc1.1.6']),
        ],
        preferCodecs: const [VideoDecodeFormatType.HEVC],
        preferQuality: 120,
        allowTenBit: false,
        allowHdrRungs: false,
      );
      expect(VideoUtils.isTenBitCodec(chosen.video.codecs), isFalse);
    });
  });

  group('the selection is the one that gets opened', () {
    test('the source key is built from the chosen rendition', () {
      final chosen = VideoUtils.selectRendition(
        videoList: [_video(120, 'hvc1.1.6.L153.90')],
        supportFormats: [_format(120, ['hvc1.1.6'])],
        preferCodecs: const [VideoDecodeFormatType.HEVC],
        preferQuality: 120,
        allowTenBit: false,
        allowHdrRungs: false,
      );
      expect(chosen.sourceKey('BV1:100'), 'BV1:100:120:hvc1.1.6.L153.90');
      expect(chosen.isExact, isTrue);
    });
  });
}
