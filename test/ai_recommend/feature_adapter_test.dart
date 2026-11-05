import 'package:PiliPlus/models/ai_recommend/video_features.dart';
import 'package:PiliPlus/models/home/rcmd/result.dart';
import 'package:PiliPlus/models/model_rec_video_item.dart';
import 'package:PiliPlus/utils/ai_recommend/ai_score_cache.dart';
import 'package:PiliPlus/utils/ai_recommend/recommendation_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

BaseRcmdVideoItemModel webItem() => RcmdVideoItemModel.fromJson({
  'id': 1,
  'bvid': 'BVweb',
  'cid': 2,
  'goto': 'av',
  'uri': 'bilibili://video/1',
  'pic': '',
  'title': '  Web 标题  ',
  'duration': 300,
  'pubdate': 1762300000,
  'owner': {'mid': 42, 'name': 'UP'},
  'stat': {'view': 1000, 'like': 100},
  'is_followed': 1,
  'rcmd_reason': {'content': '已关注'},
});

BaseRcmdVideoItemModel appItem() => RcmdVideoItemAppModel.fromJson({
  'player_args': {'aid': 9, 'cid': 10, 'duration': 120},
  'bvid': 'BVapp',
  'title': 'App 标题',
  'cover': '',
  'goto': 'av',
  'card_goto': 'av',
  'param': '9',
  'uri': 'bilibili://video/9',
  'desc': 'App 简介',
  'pubdate': 1762300000,
  'args': {'up_name': 'UP2', 'up_id': 7},
  'owner': {
    'desc_button': {'text': 'UP2'},
  },
  'stat': {'cover_left_text_1': '1000', 'cover_left_text_2': '10'},
});

void main() {
  test('both feed sources normalize into the same feature shape', () {
    final web = VideoFeatures.fromRecommendation(
      webItem(),
      index: 0,
      source: 'web',
    );
    final app = VideoFeatures.fromRecommendation(
      appItem(),
      index: 1,
      source: 'app',
    );
    expect(web.bvid, 'BVweb');
    expect(web.title, 'Web 标题');
    expect(web.source, 'web');
    expect(web.isFollowed, isTrue);
    expect(app.bvid, 'BVapp');
    expect(app.description, 'App 简介');
    expect(app.source, 'app');
    expect(app.ownerMid, 7);
    expect(app.category, '视频');
  });

  test('featuresOf deduplicates by bvid and drops empty ids', () {
    final features = AiRecommendationPipeline.featuresOf(
      [webItem(), webItem(), appItem()],
      'web',
    );
    expect(features.map((f) => f.bvid), ['BVweb', 'BVapp']);
  });

  test('cache key changes with account, keywords and provider', () {
    final feature = VideoFeatures.fromRecommendation(
      webItem(),
      index: 0,
      source: 'web',
    );
    String key({
      String scope = 'uid:1',
      String want = 'NAS',
      String provider = 'p1',
    }) => AiScoreCacheKey.build(
      accountScope: scope,
      source: 'web',
      features: feature,
      settingsFingerprint: AiScoreCacheKey.settingsFingerprint(
        wantTags: [want],
        avoidTags: const [],
        description: '',
      ),
      providerFingerprint: provider,
    );

    final base = key();
    expect(key(scope: 'uid:2'), isNot(base));
    expect(key(want: 'Flutter'), isNot(base));
    expect(key(provider: 'p2'), isNot(base));
    expect(key(), base);
  });
}
