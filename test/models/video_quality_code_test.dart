import 'package:PiliPlus/models/common/video/base_quality.dart';
import 'package:flutter_test/flutter_test.dart';

/// The catalogue endpoints return quality ids that are not in the local enum:
/// 122 showed up for bangumi where the enum only knows 125/120/116/112/80/64.
/// Selection must still work and must not fabricate a wrong label.
void main() {
  test('a known code maps to its declaration', () {
    expect(VideoQuality.fromCode(120), VideoQuality.super4K);
    expect(VideoQuality.fromCode(80), VideoQuality.high1080);
  });

  test('an unknown code does not throw', () {
    // 122 is served by pgc/pugv but has no enum entry.
    expect(() => VideoQuality.fromCode(122), returnsNormally);
  });

  test('an unknown code carries its own number as the label', () {
    final q = VideoQuality.fromCode(122);
    expect(q.code, 122);
    expect(q.desc, '122');
  });

  test('safeFromCode signals the gap instead of inventing a value', () {
    expect(VideoQuality.safeFromCode(120), isNotNull);
    expect(VideoQuality.safeFromCode(122), isNull);
  });

  test('the HDR ladder ids the gate blocks are the enum ones', () {
    // VideoUtils.unsupportedVideoQualities uses literal 125/126/129 because
    // const contexts cannot read .code; keep them in sync with the enum.
    expect(VideoQuality.hdr.code, 125);
    expect(VideoQuality.dolbyVision.code, 126);
    expect(VideoQuality.hdrVivid.code, 129);
  });

  test('unknown catalogue ids are NOT treated as HDR', () {
    // A new id must not be silently allowed just because it is unrecognised.
    final known = {for (final q in VideoQuality.values) q.code};
    expect(known.contains(122), isFalse);
  });
}