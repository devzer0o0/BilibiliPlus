import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/common/video/base_quality.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// HDR / Dolby Vision streams are 10-bit HLG/PQ. VideoToolbox decodes them to
/// `p010`, but the media_kit Darwin textures are 8-bit BGRA, so they render as
/// a green image. Until the render path handles 10-bit, those qualities must
/// never be requested or selected.
PlayUrlModel _playUrl({
  required List<int> videoIds,
  required List<int> formatIds,
  String codecs = 'hev1.2.4.L153.90',
}) => PlayUrlModel.fromJson({
  'dash': {
    'duration': 0,
    'video': [
      for (final id in videoIds)
        {
          'id': id,
          'codecs': codecs,
          'width': 3840,
          'height': 2160,
        },
    ],
  },
  'accept_quality': videoIds,
  'support_formats': [
    for (final id in formatIds)
      {
        'quality': id,
        'codecs': [codecs],
      },
  ],
});

void main() {
  test('HDR qualities are marked unsupported', () {
    expect(VideoUtils.isSupportedVideoQuality(VideoQuality.hdr.code), isFalse);
    expect(VideoUtils.isSupportedVideoQuality(VideoQuality.hdrVivid.code), isFalse);
    expect(
      VideoUtils.isSupportedVideoQuality(VideoQuality.dolbyVision.code),
      isFalse,
    );
    expect(VideoUtils.isSupportedVideoQuality(VideoQuality.super4K.code), isTrue);
    expect(VideoUtils.isSupportedVideoQuality(VideoQuality.high1080.code), isTrue);
  });

  test('requesting HDR falls back to the highest SDR stream', () {
    // Server returned the HDR ladder: 125 is first/highest.
    final playUrl = _playUrl(
      videoIds: [125, 120, 116, 80, 64, 32, 16],
      formatIds: [125, 120, 116, 80, 64, 32, 16],
    );
    final dash = playUrl.dash!;
    final (quality, _, _, _) = VideoUtils.findTargetVideo(
      dash.video!,
      VideoQuality.hdr.code,
      playUrl.acceptQuality,
      playUrl.supportFormats!,
      const [.AV1, .HEVC, .AVC],
    );
    expect(quality, VideoQuality.super4K.code);
  });

  test('asking for 4K does not silently jump to HDR', () {
    final playUrl = _playUrl(
      videoIds: [125, 120, 80, 32],
      formatIds: [125, 120, 80, 32],
    );
    final dash = playUrl.dash!;
    final (quality, _, _, _) = VideoUtils.findTargetVideo(
      dash.video!,
      VideoQuality.super4K.code,
      playUrl.acceptQuality,
      playUrl.supportFormats!,
      const [.AV1, .HEVC, .AVC],
    );
    expect(quality, VideoQuality.super4K.code);
  });

  test('a stream ladder with only HDR still yields a playable id', () {
    final playUrl = _playUrl(videoIds: [125], formatIds: [125]);
    final dash = playUrl.dash!;
    final (quality, _, _, _) = VideoUtils.findTargetVideo(
      dash.video!,
      VideoQuality.super4K.code,
      playUrl.acceptQuality,
      playUrl.supportFormats!,
      const [.HEVC],
    );
    // No SDR rendition exists; keep the only one rather than crash.
    expect(quality, 125);
  });

  test('1080P request is honoured exactly', () {
    final playUrl = _playUrl(
      videoIds: [125, 120, 116, 80, 32],
      formatIds: [125, 120, 116, 80, 32],
    );
    final dash = playUrl.dash!;
    final (quality, _, _, _) = VideoUtils.findTargetVideo(
      dash.video!,
      VideoQuality.high1080.code,
      playUrl.acceptQuality,
      playUrl.supportFormats!,
      const [.AV1, .HEVC, .AVC],
    );
    expect(quality, VideoQuality.high1080.code);
  });
}
