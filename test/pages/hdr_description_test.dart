import 'package:PiliPlus/plugin/pl_player/widgets/hdr_video_surface.dart';
import 'package:flutter_test/flutter_test.dart';

/// Dynamic range is three answers, not one.
///
/// The bug: `videoRange(for:)` turned HEVC Main10 into PQ and every other codec
/// into SDR. 10-bit is not a transfer function, Bilibili ships HLG as well as
/// PQ, and AV1 HDR is not HEVC at all. Downstream, a missing descriptor was
/// read as "confirmed SDR".
void main() {
  group('the source description keeps unknown as unknown', () {
    test('a map without colour metadata claims neither HDR nor SDR', () {
      final info = HdrPlaybackInfo.fromMap({'seconds': 1.0, 'ready': true});
      expect(info.hdr, isNull);
      expect(info.dynamicRangeLabel, '未知');
    });

    test('an explicit SDR statement is reported as SDR', () {
      final info = HdrPlaybackInfo.fromMap({
        'hdr': false,
        'transferFunction': 'SDR',
      });
      expect(info.hdr, isFalse);
      expect(info.dynamicRangeLabel, 'SDR');
    });

    test('PQ is HDR10 and HLG is HLG - they are not interchangeable', () {
      final pq = HdrPlaybackInfo.fromMap({
        'hdr': true,
        'transferFunction': 'PQ',
        'transfer': 'SMPTE ST 2084 (PQ)',
      });
      final hlg = HdrPlaybackInfo.fromMap({
        'hdr': true,
        'transferFunction': 'HLG',
        'transfer': 'ITU_R_2100_HLG',
      });
      expect(pq.dynamicRangeLabel, 'HDR10');
      expect(hlg.dynamicRangeLabel, 'HLG');
      expect(pq.dynamicRangeLabel, isNot(hlg.dynamicRangeLabel));
    });

    test('Dolby Vision is named as such, not as plain HEVC', () {
      final info = HdrPlaybackInfo.fromMap({
        'hdr': true,
        'dolbyVision': {'profile': 5, 'level': 6},
      });
      expect(info.dynamicRangeLabel, 'Dolby Vision');
      expect(info.dolbyVision, isNotNull);
    });

    test('10-bit SDR is SDR', () {
      final info = HdrPlaybackInfo.fromMap({
        'hdr': false,
        'transferFunction': 'SDR',
        'bitDepth': 10,
      });
      expect(info.dynamicRangeLabel, 'SDR');
      expect(info.bitDepth, 10);
    });
  });

  group('what the panel reports', () {
    test('the coded size wins over the presentation size', () {
      final info = HdrPlaybackInfo.fromMap({
        'codedWidth': 3840,
        'codedHeight': 2160,
        'width': 1920,
        'height': 1080,
      });
      expect(info.width, 3840);
      expect(info.height, 2160);
    });

    test('edrRequested is a request, not proof of presentation', () {
      final info = HdrPlaybackInfo.fromMap({
        'hdr': true,
        'transferFunction': 'PQ',
        'edrRequested': true,
      });
      // The label describes the source; nothing here claims the screen.
      expect(info.dynamicRangeLabel, 'HDR10');
      expect(info.edrRequested, isTrue);
    });
  });
}
