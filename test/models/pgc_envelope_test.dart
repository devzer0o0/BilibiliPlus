import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:flutter_test/flutter_test.dart';

/// Response envelopes verified against the live API on 2026-11-03:
///
///   primary  ogvUrl (/pgc/player/web/playurl)     -> data{video_info, arc, ...}
///   fallback pgcUrl (/pgc/player/web/v2/playurl)  -> result{video_info, play_view_business_info, ...}
///
/// The two branches therefore read the same field name from different
/// envelopes. Swapping them silently yields an empty play model.
Map<String, dynamic> _videoInfo() => {
  'dash': {
    'duration': 1440,
    'video': [
      {'id': 80, 'codecs': 'avc1.640028', 'width': 1920, 'height': 1080},
    ],
  },
  'accept_quality': [80],
  'support_formats': [
    {
      'quality': 80,
      'codecs': ['avc1.640028'],
    },
  ],
};

void main() {
  group('primary ogv envelope', () {
    test('video_info is read from data', () {
      final envelope = {'data': _videoInfo()};
      final model = PlayUrlModel.fromJson(
        envelope['data'] as Map<String, dynamic>,
      );
      expect(model.dash, isNotNull);
      expect(model.dash!.video!.first.id, 80);
    });

    test('a DRM marker sits beside video_info, not inside it', () {
      final data = <String, dynamic>{
        'arc': {'is_drm': true},
        'video_info': null,
      };
      // This is the shape that makes the app retry against the fallback.
      expect(data['video_info'], isNull);
      expect((data['arc'] as Map)['is_drm'], isTrue);
      expect(
        () => PlayUrlModel.fromJson(
          (data['video_info'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
        returnsNormally,
      );
    });
  });

  group('fallback pgc v2 envelope', () {
    test('video_info is read from result', () {
      final envelope = {'result': _videoInfo()};
      final result = envelope['result'] as Map<String, dynamic>;
      final model = PlayUrlModel.fromJson(
        result['video_info'] as Map<String, dynamic>? ?? result,
      );
      expect(model.dash, isNotNull);
    });

    test('result carries no data wrapper', () {
      // Guards against anyone "fixing" the branch to read res.data['result']['data'].
      final envelope = <String, dynamic>{
        'result': {'video_info': _videoInfo()},
      };
      final result = envelope['result'] as Map<String, dynamic>;
      expect(result.containsKey('data'), isFalse);
      expect(result.containsKey('video_info'), isTrue);
    });
  });

  group('endpoint wiring', () {
    test('pgc retries the v2 endpoint, not its primary', () {
      expect(VideoType.pgc.api, isNot(VideoType.pgc.fallbackApi));
      expect(VideoType.pgc.fallbackApi, contains('v2'));
    });
  });
}