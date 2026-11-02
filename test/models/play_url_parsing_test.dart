import 'package:PiliPlus/models/video/play/url.dart';
import 'package:flutter_test/flutter_test.dart';

/// The DRM fallback re-parses a different response envelope. Each branch of
/// `VideoHttp.videoUrl` feeds `PlayUrlModel.fromJson` a different sub-map, so
/// a wrong path silently yields a playable-looking but empty model.
PlayUrlModel _withDash(Map<String, dynamic> extra) => PlayUrlModel.fromJson({
  'dash': {
    'duration': 120,
    'video': [
      {'id': 120, 'codecs': 'avc1.640032', 'width': 3840, 'height': 2160},
    ],
  },
  'accept_quality': [120],
  'support_formats': [
    {
      'quality': 120,
      'codecs': ['avc1.640032'],
    },
  ],
  ...extra,
});

void main() {
  group('catalogue payload shapes', () {
    test('a bare video_info map parses into a dash model', () {
      final model = _withDash(const {});
      expect(model.dash, isNotNull);
      expect(model.dash!.video, isNotEmpty);
      expect(model.dash!.video!.first.id, 120);
    });

    test('a missing watch progress defaults to 0, not null', () {
      // lastPlayTime falls back to 0, so callers can compare it numerically;
      // the two branches only overwrite it when the envelope carries progress.
      final model = _withDash(const {});
      expect(model.lastPlayTime, 0);
    });

    test('progress carried in the envelope is picked up', () {
      final model = _withDash(const {'last_play_time': 42});
      expect(model.lastPlayTime, 42);
    });
  });

  group('missing fields degrade quietly', () {
    test('an empty map does not throw', () {
      expect(() => PlayUrlModel.fromJson(const {}), returnsNormally);
    });

    test('a map with no dash yields a null dash rather than throwing', () {
      final model = PlayUrlModel.fromJson(const {'result': 'suee'});
      expect(model.dash, isNull);
      expect(model.result, 'suee');
    });

    test('a DRM rejection envelope has no playable data', () {
      // This is the shape that triggers the fallback retry.
      final model = PlayUrlModel.fromJson(const {
        'arc': {'is_drm': true},
      });
      expect(model.dash, isNull);
    });
  });
}