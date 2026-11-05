import 'package:PiliPlus/models/ai_recommend/ai_recommend_settings.dart';
import 'package:PiliPlus/models/ai_recommend/ai_score.dart';
import 'package:PiliPlus/models/ai_recommend/interest_profile.dart';
import 'package:PiliPlus/models/ai_recommend/video_features.dart';
import 'package:PiliPlus/utils/ai_recommend/recommendation_ranker.dart';
import 'package:flutter_test/flutter_test.dart';

VideoFeatures video(
  String bvid,
  String title, {
  int index = 0,
  int? ownerMid,
  bool followed = false,
  int? pubdate,
}) => VideoFeatures(
  bvid: bvid,
  title: title,
  ownerMid: ownerMid,
  ownerName: 'up',
  isFollowed: followed,
  pubdate: pubdate ?? DateTime(2026, 11, 1).millisecondsSinceEpoch ~/ 1000,
  upstreamIndex: index,
);

AiCandidateScore score(
  String bvid,
  double relevance, {
  double confidence = 1,
}) => AiCandidateScore(
  candidateId: 'c1',
  bvid: bvid,
  relevance: relevance,
  confidence: confidence,
);

InterestProfile profileWith(String label, double weight) => InterestProfile(
  accountScope: 'uid:1',
  topics: {
    InterestProfile.topicId(label): TopicPreference(
      id: InterestProfile.topicId(label),
      label: label,
      recent: weight,
      long: weight,
      confidence: 0.8,
      hits: 3,
      updatedAtMs: DateTime(2026, 11, 1).millisecondsSinceEpoch,
    ),
  },
);

void main() {
  const ranker = RecommendationRanker();
  final now = DateTime(2026, 11, 5);

  test('no keywords, no profile and no model keeps upstream order', () {
    final result = ranker.rank(
      candidates: [
        video('BV1', 'A', index: 0),
        video('BV2', 'B', index: 1),
        video('BV3', 'C', index: 2),
      ],
      settings: const AiRecommendSettings(enabled: true),
      now: now,
    );
    expect(result.items.map((e) => e.features.bvid), ['BV1', 'BV2', 'BV3']);
    expect(result.usedModel, isFalse);
    expect(result.items.first.reason, contains('原排序'));
  });

  test('explicit want phrase outranks the upstream position', () {
    final result = ranker.rank(
      candidates: [
        video('BV1', '今天玩游戏', index: 0),
        video('BV2', 'NAS 搭建教程', index: 1),
      ],
      settings: const AiRecommendSettings(
        enabled: true,
        wantTags: ['NAS'],
      ),
      now: now,
    );
    expect(result.items.first.features.bvid, 'BV2');
    expect(result.items.first.reason, contains('NAS'));
  });

  test('avoid phrase folds without deleting the candidate', () {
    final result = ranker.rank(
      candidates: [
        video('BV1', '游戏实况', index: 0),
        video('BV2', 'NAS 教程', index: 1),
      ],
      settings: const AiRecommendSettings(
        enabled: true,
        avoidTags: ['游戏'],
      ),
      now: now,
    );
    expect(result.items.map((e) => e.features.bvid), ['BV2']);
    expect(result.folded.single.features.bvid, 'BV1');
    expect(result.folded.single.reason, contains('游戏'));
  });

  test('a followed up is not folded', () {
    final result = ranker.rank(
      candidates: [
        video('BV1', '游戏实况', index: 0, followed: true),
      ],
      settings: const AiRecommendSettings(
        enabled: true,
        avoidTags: ['游戏'],
      ),
      now: now,
    );
    expect(result.folded, isEmpty);
    expect(result.items.length, 1);
  });

  test('strict keeps unknown items and drops only low model relevance', () {
    final result = ranker.rank(
      candidates: [
        video('BV1', 'A', index: 0),
        video('BV2', 'B', index: 1),
        video('BV3', 'C', index: 2),
      ],
      settings: const AiRecommendSettings(
        enabled: true,
        mode: AiRecommendMode.strict,
        strictThreshold: 0.5,
      ),
      scores: {
        'BV1': score('BV1', 0.9),
        'BV2': score('BV2', 0.2),
      },
      now: now,
    );
    final ids = result.items.map((e) => e.features.bvid).toList();
    expect(ids, containsAll(['BV1', 'BV3']));
    expect(ids, isNot(contains('BV2')));
    expect(result.strictDropped, 1);
    expect(result.usedModel, isTrue);
  });

  test('strict without model scores filters nothing and says so', () {
    final result = ranker.rank(
      candidates: [video('BV1', 'A'), video('BV2', 'B')],
      settings: const AiRecommendSettings(
        enabled: true,
        mode: AiRecommendMode.strict,
      ),
      now: now,
    );
    expect(result.items.length, 2);
    expect(result.usedModel, isFalse);
    expect(result.strictDropped, 0);
  });

  test('low-confidence model score moves less than a confident one', () {
    final base = ranker.rank(
      candidates: [
        video('BV1', 'A', index: 0),
        video('BV2', 'B', index: 1),
      ],
      settings: const AiRecommendSettings(enabled: true),
      scores: {
        'BV1': score('BV1', 0.1, confidence: 1),
        'BV2': score('BV2', 0.9, confidence: 1),
      },
      now: now,
    );
    expect(base.items.first.features.bvid, 'BV2');

    final weak = ranker.rank(
      candidates: [
        video('BV1', 'A', index: 0),
        video('BV2', 'B', index: 1),
      ],
      settings: const AiRecommendSettings(enabled: true),
      scores: {
        'BV1': score('BV1', 0.1, confidence: 0.05),
        'BV2': score('BV2', 0.9, confidence: 0.05),
      },
      now: now,
    );
    final gapStrong = base.items.first.score - base.items.last.score;
    final gapWeak = weak.items.first.score - weak.items.last.score;
    expect(gapWeak.abs(), lessThan(gapStrong.abs() + 0.2));
  });

  test('profile topic lifts a matching title', () {
    final result = ranker.rank(
      candidates: [
        video('BV1', '普通视频', index: 0),
        video('BV2', 'Flutter 状态管理实践', index: 1),
      ],
      settings: const AiRecommendSettings(enabled: true),
      profile: profileWith('Flutter', 0.8),
      now: now,
    );
    expect(result.items.first.features.bvid, 'BV2');
    expect(result.items.first.reason, contains('Flutter'));
  });

  test('no duplicate candidates are introduced and none are dropped', () {
    final candidates = [
      video('BV1', 'A', index: 0),
      video('BV2', 'B', index: 1),
      video('BV3', 'C', index: 2),
      video('BV4', 'D', index: 3),
    ];
    final result = ranker.rank(
      candidates: candidates,
      settings: const AiRecommendSettings(enabled: true),
      now: now,
    );
    expect(result.items.length, candidates.length);
    expect(result.items.map((e) => e.features.bvid).toSet().length, 4);
  });

  test('repeated author is separated without removing a card', () {
    final result = ranker.rank(
      candidates: [
        video('BV1', 'A', index: 0, ownerMid: 7),
        video('BV2', 'B', index: 1, ownerMid: 7),
        video('BV3', 'C', index: 2, ownerMid: 9),
        video('BV4', 'D', index: 3, ownerMid: 11),
      ],
      settings: const AiRecommendSettings(enabled: true, explorationRatio: 0),
      now: now,
    );
    expect(result.items.length, 4);
    expect(result.items.map((e) => e.features.bvid).toSet().length, 4);
  });
}
