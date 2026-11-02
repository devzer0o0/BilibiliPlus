import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// Streams that only ship one codec (8K AV1 uploads, H.264-only HDR uploads)
/// must still resolve to a playable rendition instead of failing the lookup.
void main() {
  test('a stream with only AVC keeps AVC even when AV1 is preferred', () {
    final chosen = VideoUtils.selectCodec(
      ['avc1.640033'],
      const [.AV1, .HEVC, .AVC],
    );
    expect(chosen, VideoDecodeFormatType.AVC);
  });

  test('a stream with only HEVC keeps HEVC', () {
    final chosen = VideoUtils.selectCodec(
      ['hev1.1.6.L120.90'],
      const [.AV1, .HEVC, .AVC],
    );
    expect(chosen, VideoDecodeFormatType.HEVC);
  });

  test('a Dolby Vision stream resolves to DVH1 even when it is last', () {
    final chosen = VideoUtils.selectCodec(
      ['dvh1.08.07'],
      const [.AV1, .HEVC, .AVC, .DVH1],
    );
    expect(chosen, VideoDecodeFormatType.DVH1);
  });

  test('an unknown codec falls back instead of throwing', () {
    // vp09 is not in VideoDecodeFormatType; the lookup used to throw
    // "Bad state: No element" and abort playback.
    final chosen = VideoUtils.selectCodec(
      ['vp09.00.10.08'],
      const [.AV1, .HEVC, .AVC],
    );
    expect(chosen, VideoDecodeFormatType.AV1);
  });

  test('an empty preference list falls back to the first known codec', () {
    final chosen = VideoUtils.selectCodec(['avc1.640033'], const []);
    expect(chosen, VideoDecodeFormatType.AVC);
  });
}
