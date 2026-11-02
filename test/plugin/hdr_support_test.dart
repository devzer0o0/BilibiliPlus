import 'package:PiliPlus/models/common/video/base_quality.dart';
import 'package:PiliPlus/plugin/pl_player/utils/hdr_support.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// Flutter's iOS external texture accepts only 32BGRA and the two 8-bit
/// biplanar formats (FlutterTexture.h), so a true 10-bit path is not available.
/// HDR must therefore stay gated until tone mapping is verified.
void main() {
  test('the native 10-bit path stays disabled until the engine supports it', () {
    expect(HdrSupport.nativeTenBitPath, isFalse);
  });

  test('HDR qualities are blocked while the gate is off', () {
    expect(HdrSupport.enableToneMappedHdr, isFalse);
    expect(HdrSupport.allowsHdrQuality, isFalse);
    expect(VideoUtils.isSupportedVideoQuality(VideoQuality.hdr.code), isFalse);
    expect(
      VideoUtils.isSupportedVideoQuality(VideoQuality.dolbyVision.code),
      isFalse,
    );
    expect(VideoUtils.isSupportedVideoQuality(VideoQuality.hdrVivid.code), isFalse);
  });

  test('SDR qualities remain selectable', () {
    for (final q in [
      VideoQuality.super8k,
      VideoQuality.super4K,
      VideoQuality.high108060,
      VideoQuality.high1080,
      VideoQuality.clear480,
    ]) {
      expect(VideoUtils.isSupportedVideoQuality(q.code), isTrue, reason: q.desc);
    }
    expect(VideoUtils.isSupportedVideoQuality(null), isTrue);
  });

  test('the tone mapping options match what libplacebo expects', () {
    expect(HdrSupport.toneMappedPlayerOptions, {
      'tone-mapping': 'auto',
      'hdr-compute-peak': 'yes',
      'target-colorspace-hint': 'yes',
    });
  });
}
