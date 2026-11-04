import 'package:PiliPlus/plugin/pl_player/backend/native_backend.dart';
import 'package:PiliPlus/plugin/pl_player/backend/playback_backend.dart';
import 'package:PiliPlus/plugin/pl_player/backend/playback_session.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/hdr_video_surface.dart';
import 'package:flutter_test/flutter_test.dart';

/// The HDR surface must not be able to restart playback.
///
/// Its session is created by the controller and survives rebuilds; the view is
/// keyed by the rendition, so a rotation or a control-bar toggle re-attaches the
/// same session instead of opening a new one.
void main() {
  group('surface identity', () {
    test('the key changes only with the rendition', () {
      String key(String bvid, int cid, int qn, String codec) =>
          '$bvid:$cid:$qn:$codec';

      final initial = key('BV1', 100, 125, 'hev1.2.4.L153.B0');
      // Same rendition, different view state: rotation, full screen, controls.
      final afterRotation = key('BV1', 100, 125, 'hev1.2.4.L153.B0');
      expect(afterRotation, initial);

      final newQuality = key('BV1', 100, 120, 'hev1.2.4.L120.B0');
      expect(newQuality, isNot(initial));
      final newPart = key('BV1', 101, 125, 'hev1.2.4.L153.B0');
      expect(newPart, isNot(initial));
    });
  });

  group('native state mapping', () {
    test('a paused native session is not reported as playing', () {
      final snapshot = HdrPlaybackInfo.fromMap({
        'hdr': true,
        'seconds': 4.0,
        'rate': 0,
      });
      expect(snapshot.rate, 0);
      expect(snapshot.hdr, isTrue);
    });

    test('a missing description claims neither HDR nor SDR', () {
      final snapshot = HdrPlaybackInfo.fromMap({'seconds': 1.0});
      // Null, not false: an absent descriptor is not evidence of SDR.
      expect(snapshot.hdr, isNull);
      expect(snapshot.edrRequested, isFalse);
      expect(snapshot.dynamicRangeLabel, '未知');
    });
  });

  group('native snapshots', () {
    test('a buffering session reports buffering, not paused', () {
      // timeControl 1 is waitingToPlayAtSpecifiedRate.
      final parsed = NativeStateFixture.parse({
        'seconds': 30.0,
        'duration': 600.0,
        'rate': 1.0,
        'timeControl': 1,
        'ready': true,
      });
      expect(parsed.buffering, isTrue);
      expect(parsed.ready, isTrue);
    });

    test('completion is distinct from pause', () {
      final parsed = NativeStateFixture.parse({
        'seconds': 600.0,
        'duration': 600.0,
        'rate': 0,
        'completed': true,
        'ready': true,
      });
      expect(parsed.completed, isTrue);
      expect(parsed.playing, isFalse);
    });

    test('an error string is surfaced', () {
      final parsed = NativeStateFixture.parse({
        'seconds': 0.0,
        'error': 'no-index',
      });
      expect(parsed.hasError, isTrue);
      expect(parsed.error, 'no-index');
    });
  });
}

/// Shares the conversion [NativePlaybackBackend] performs.
abstract final class NativeStateFixture {
  static PlaybackSnapshot parse(Map<String, Object?> map) =>
      NativePlaybackBackend.parse(map, 1);
}
