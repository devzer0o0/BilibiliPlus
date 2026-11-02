import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:flutter_test/flutter_test.dart';

/// DRM-protected catalogue content cannot be fetched from the ogv endpoint,
/// so `VideoHttp.videoUrl` retries against `fallbackApi` with `fallback: true`.
/// That retry depends entirely on these enum fields being wired correctly,
/// and getting them wrong shows up as unplayable paid/episode content.
void main() {
  group('fallback routing', () {
    test('ugc keeps the same endpoint for the fallback', () {
      expect(VideoType.ugc.fallbackApi, VideoType.ugc.api);
    });

    test('pgc and pugv fall back to a different endpoint than their primary', () {
      expect(VideoType.pgc.fallbackApi, isNot(VideoType.pgc.api));
      expect(VideoType.pugv.fallbackApi, isNot(VideoType.pugv.api));
    });

    test('pgc and pugv share the ogv primary but differ on fallback', () {
      // Both catalogue types start at ogv, so a copy-paste mistake here would
      // send one of them to the wrong retry endpoint.
      expect(VideoType.pgc.api, VideoType.pugv.api);
      expect(VideoType.pgc.fallbackApi, isNot(VideoType.pugv.fallbackApi));
    });

    test('every type has a non-empty fallback', () {
      for (final t in VideoType.values) {
        expect(t.fallbackApi, isNotEmpty, reason: t.name);
      }
    });
  });

  group('bizType', () {
    test('only catalogue types send a biz_type', () {
      // ugc must not send biz_type; the ogv endpoint rejects it.
      expect(VideoType.ugc.bizType, isNull);
      expect(VideoType.pgc.bizType, 'ogv');
      expect(VideoType.pugv.bizType, 'pugv');
    });
  });

  group('type codes', () {
    test('the numeric types stay stable', () {
      // These values travel to the reply and history endpoints.
      expect(VideoType.ugc.type, 3);
      expect(VideoType.pgc.type, 4);
      expect(VideoType.pugv.type, 10);
    });

    test('pugv replies use type 33, the others default to 1', () {
      expect(VideoType.pugv.replyType, 33);
      expect(VideoType.ugc.replyType, 1);
      expect(VideoType.pgc.replyType, 1);
    });
  });
}