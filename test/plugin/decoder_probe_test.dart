import 'package:PiliPlus/plugin/pl_player/utils/decoder_probe.dart';
import 'package:flutter_test/flutter_test.dart';

/// A measurement that cannot be taken must not read as a pass.
///
/// `hwdec=videotoolbox` is a configuration request; these are the numbers that
/// say what mpv actually did, and the difference between "zero dropped frames"
/// and "this libmpv does not report dropped frames" is the whole point.
void main() {
  group('unavailable is not zero', () {
    test('a build without the drop counters reports them unavailable', () {
      const observation = DecoderObservation(hwdecCurrent: 'videotoolbox');
      expect(observation.frameDropCount, isNull);
      expect(observation.available, contains('hwdec-current'));
      expect(observation.unavailable, contains('frame-drop-count'));
      expect(observation.unavailable, contains('decoder-frame-drop-count'));
    });

    test('a real zero is kept as zero', () {
      const observation = DecoderObservation(
        frameDropCount: 0,
        decoderFrameDropCount: 0,
      );
      expect(observation.frameDropCount, 0);
      expect(observation.unavailable, isNot(contains('frame-drop-count')));
    });
  });

  group('decoding mode is reported, not assumed', () {
    test('videotoolbox is hardware', () {
      const observation = DecoderObservation(hwdecCurrent: 'videotoolbox');
      expect(observation.hardwareDecoding, isTrue);
      expect(observation.softwareDecoding, isFalse);
    });

    test('no means software, which is a finding and not a detail', () {
      const observation = DecoderObservation(hwdecCurrent: 'no');
      expect(observation.softwareDecoding, isTrue);
      expect(observation.hardwareDecoding, isFalse);
    });
  });

  group('cumulative counters become deltas', () {
    test('the delta is the difference, not the sum', () {
      const before = DecoderObservation(
        frameDropCount: 100,
        decoderFrameDropCount: 40,
      );
      const after = DecoderObservation(
        frameDropCount: 112,
        decoderFrameDropCount: 45,
      );
      final delta = after.deltaFrom(before);
      expect(delta.frameDropCount, 12);
      expect(delta.decoderFrameDropCount, 5);
    });

    test('a counter that disappeared does not fabricate a delta', () {
      const before = DecoderObservation(frameDropCount: 100);
      const after = DecoderObservation();
      expect(after.deltaFrom(before).frameDropCount, isNull);
    });
  });

  test('the probe is inert when disabled', () {
    // No Player is needed: the disabled path returns before touching one.
    const observation = DecoderObservation();
    expect(observation.available, isEmpty);
    expect(observation.unavailable, isNotEmpty);
  });
}
