import 'package:PiliPlus/models/common/video/base_quality.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every place that lets the user pick a quality must honour the HDR gate,
/// otherwise a stored HDR default re-enables the green-screen stream.
void main() {
  List<int> offered() => VideoQuality.values
      .where((e) => VideoUtils.isSupportedVideoQuality(e.code))
      .map((e) => e.code)
      .toList();

  test('the default-quality picker never offers HDR levels', () {
    final codes = offered();
    for (final hdr in [125, 126, 129]) {
      expect(codes, isNot(contains(hdr)), reason: 'HDR $hdr must be hidden');
    }
  });

  test('the SDR ladder is still complete', () {
    final codes = offered();
    for (final sdr in [
      VideoQuality.super8k.code,
      VideoQuality.super4K.code,
      VideoQuality.high108060.code,
      VideoQuality.high1080plus.code,
      VideoQuality.high1080.code,
      VideoQuality.high72060.code,
      VideoQuality.high720.code,
      VideoQuality.clear480.code,
      VideoQuality.fluent360.code,
      VideoQuality.speed240.code,
    ]) {
      expect(codes, contains(sdr));
    }
  });

  test('a stored HDR default is not honoured as selectable', () {
    // Users upgrading from an older build may already have 125 stored.
    expect(VideoUtils.isSupportedVideoQuality(125), isFalse);
  });
}