import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// On iOS the AV1 VideoToolbox decoder is available for every device shipping
/// the patched Avcodec framework, so AV1 is preferred over HEVC: it has no
/// royalty cost and Bilibili serves it at the same quality ladder.
void main() {
  const av1 = 'av01.0.08M.08.0.110.01.01.01.0';
  const hevc = 'hvc1.1.6.L120.90';
  const avc = 'avc1.640033';

  test('AV1 wins when both AV1 and HEVC are offered', () {
    final chosen = VideoUtils.selectCodec(
      [hevc, avc, av1],
      const [.AV1, .HEVC, .AVC],
    );
    expect(chosen, VideoDecodeFormatType.AV1);
  });

  test('falls back to HEVC when AV1 is missing', () {
    final chosen = VideoUtils.selectCodec([hevc, avc], const [.AV1, .HEVC, .AVC]);
    expect(chosen, VideoDecodeFormatType.HEVC);
  });

  test('falls back to AVC when only AVC is offered', () {
    final chosen = VideoUtils.selectCodec([avc], const [.AV1, .HEVC, .AVC]);
    expect(chosen, VideoDecodeFormatType.AVC);
  });

  test('HEVC-first preference still selects HEVC when both exist', () {
    final chosen = VideoUtils.selectCodec(
      [av1, hevc],
      const [.HEVC, .AVC, .AV1],
    );
    expect(chosen, VideoDecodeFormatType.HEVC);
  });

  test('Dolby Vision stays ahead of the SDR codecs', () {
    final chosen = VideoUtils.selectCodec(
      ['dvh1.08.07', av1, hevc],
      const [.DVH1, .AV1, .HEVC, .AVC],
    );
    expect(chosen, VideoDecodeFormatType.DVH1);
  });
}
