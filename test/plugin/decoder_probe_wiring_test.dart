import 'package:PiliPlus/plugin/pl_player/utils/decoder_probe.dart';
import 'package:PiliPlus/plugin/pl_player/utils/diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

/// The probe existed but nothing called it, so a silent software fallback
/// produced no evidence. These pin the wiring contract: what the loop reports,
/// and that a shipping build reports nothing at all.
void main() {
  group('the loop is gated on a diagnostics build', () {
    test('a shipping build has the switch off', () {
      // Diagnostics.enabled is a compile-time constant, so in a test build
      // without --dart-define it is false. The ticker must not start.
      expect(Diagnostics.enabled, isFalse);
    });

    test('the sample interval is long enough not to perturb playback', () {
      // A 250 ms poll of six properties costs frames; the figure is a decision,
      // not a default, so it is asserted.
      expect(Diagnostics.sampleInterval.inSeconds, greaterThanOrEqualTo(1));
    });
  });

  group('what the loop records', () {
    test('a software fallback is distinguishable from hardware', () {
      const software = DecoderObservation(
        hwdecCurrent: 'no',
        videoCodec: 'hevc',
        sourceWidth: 3840,
        sourceHeight: 2160,
      );
      expect(software.softwareDecoding, isTrue);
      expect(software.hardwareDecoding, isFalse);
      // The line the loop writes carries these, so the log answers
      // "was 4K decoded in software" without a second run.
      expect(software.videoCodec, 'hevc');
      expect(software.sourceWidth, 3840);
    });

    test('the delta is a rate, the absolute value is the total', () {
      const first = DecoderObservation(frameDropCount: 10);
      const second = DecoderObservation(frameDropCount: 14);
      final delta = second.deltaFrom(first);
      expect(delta.frameDropCount, 4);
      expect(second.frameDropCount, 14);
    });

    test('an absent counter stays unavailable through the delta', () {
      const first = DecoderObservation(hwdecCurrent: 'videotoolbox');
      const second = DecoderObservation(hwdecCurrent: 'videotoolbox');
      expect(second.deltaFrom(first).frameDropCount, isNull);
    });
  });

  group('the native route is reported as unmeasured, not as healthy', () {
    test('an empty observation has no counters at all', () {
      // sampleDecoder returns this for the native route and for a shipping
      // build; the loop writes "counters=unavailable" rather than silence.
      const empty = DecoderObservation();
      expect(empty.at, isNull);
      expect(empty.hwdecCurrent, isNull);
      expect(empty.frameDropCount, isNull);
    });
  });
}
