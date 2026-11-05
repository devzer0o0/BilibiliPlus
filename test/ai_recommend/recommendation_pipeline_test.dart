import 'dart:async';

import 'package:PiliPlus/models/ai_recommend/ai_recommend_settings.dart';
import 'package:PiliPlus/models/ai_recommend/interest_profile.dart';
import 'package:PiliPlus/models/ai_recommend/ai_score.dart';
import 'package:PiliPlus/models/ai_recommend/video_features.dart';
import 'package:PiliPlus/utils/ai_recommend/ai_provider.dart';
import 'package:PiliPlus/utils/ai_recommend/ai_score_cache.dart';
import 'package:PiliPlus/utils/ai_recommend/ai_usage.dart';
import 'package:PiliPlus/utils/ai_recommend/interest_profile_repository.dart';
import 'package:PiliPlus/utils/ai_recommend/recommendation_pipeline.dart';
import 'package:PiliPlus/utils/security/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeProvider implements AiProvider {
  FakeProvider(this.handler);

  Future<AiProviderResult> Function(AiBatchRequest) handler;
  int calls = 0;
  final List<AiBatchRequest> requests = [];

  @override
  Future<AiProviderResult> score(AiBatchRequest request) {
    calls++;
    requests.add(request);
    return handler(request);
  }
}

AiProviderResult resultFor(
  AiBatchRequest request, {
  double Function(String title)? relevanceFor,
  Set<String>? only,
}) {
  final scoreOf = relevanceFor ?? (_) => 0.5;
  final scores = <String, AiCandidateScore>{};
  for (final c in request.candidates) {
    if (only != null && !only.contains(c.features.bvid)) continue;
    scores[c.features.bvid] = AiCandidateScore(
      candidateId: c.requestId,
      bvid: c.features.bvid,
      relevance: scoreOf(c.features.title),
      confidence: 1,
      topics: const ['测试主题'],
    );
  }
  return AiProviderResult(
    scores: AiScoreParseResult(
      scoresByBvid: scores,
      invalidItems: 0,
      missingIds: const [],
    ),
    promptTokens: 100,
    completionTokens: 20,
  );
}

VideoFeatures f(String bvid, String title, int index) => VideoFeatures(
  bvid: bvid,
  title: title,
  durationSeconds: 300,
  ownerMid: index + 1,
  pubdate: DateTime(2026, 11, 1).millisecondsSinceEpoch ~/ 1000,
  upstreamIndex: index,
);

void main() {
  late MemoryInterestProfileStore profiles;
  late MemoryAiScoreCache cache;
  late MemoryAiUsageStore usage;
  late MemorySecretStore secrets;
  late FakeProvider provider;
  late AiRecommendSettings settings;

  setUp(() {
    profiles = MemoryInterestProfileStore();
    cache = MemoryAiScoreCache(now: DateTime(2026, 11, 5));
    usage = MemoryAiUsageStore();
    secrets = MemorySecretStore({SecretKeys.aiApiKey: 'test-key'});
    settings = const AiRecommendSettings(
      enabled: true,
      baseUrl: 'https://model.example/v1',
      model: 'test-model',
      firstPaintBudgetMs: 500,
      dailyRequestBudget: 10,
    );
    provider = FakeProvider((request) async {
      return resultFor(
        request,
        relevanceFor: (title) => title.contains('Flutter') ? 0.95 : 0.2,
      );
    });
  });

  AiRecommendationPipeline pipeline() => AiRecommendationPipeline(
    settingsLoader: () async => settings,
    profileStore: profiles,
    cache: cache,
    usage: usage,
    secrets: secrets,
    providerFactory: (_) => provider,
    clock: () => DateTime(2026, 11, 5),
  );

  test('model scores actually change order and consume budget', () async {
    final candidates = [
      f('BV1', '游戏', 0),
      f('BV2', 'Flutter 状态管理', 1),
      f('BV3', '日常', 2),
    ];
    final page = await pipeline().rankFeatures(
      features: candidates,
      source: 'web',
      accountScope: 'uid:1',
      token: RecommendationSession().begin(),
    );
    expect(page.status, AiFeedStatus.active);
    expect(page.freshScores, 3);
    expect(page.items.first.features.bvid, 'BV2');
    expect(page.requestsToday, 1);
    expect(
      await usage.read('uid:1', DateTime(2026, 11, 5)).then((s) => s.requests),
      1,
    );
  });

  test(
    'second refresh reuses cache instead of calling the model again',
    () async {
      final candidates = [f('BV1', 'A', 0), f('BV2', 'B', 1)];
      final p = pipeline();
      await p.rankFeatures(
        features: candidates,
        source: 'web',
        accountScope: 'uid:1',
        token: RecommendationSession().begin(),
      );
      expect(provider.calls, 1);

      provider.handler = (_) async => throw StateError('must not be called');
      final page = await p.rankFeatures(
        features: candidates,
        source: 'web',
        accountScope: 'uid:1',
        token: RecommendationSession().begin(),
      );
      expect(provider.calls, 1);
      expect(page.cacheHits, 2);
      expect(page.status, AiFeedStatus.cached);
    },
  );

  test('budget zero means no request and a clear status', () async {
    settings = settings.copyWith(dailyRequestBudget: 0);
    final page = await pipeline().rankFeatures(
      features: [f('BV1', 'A', 0)],
      source: 'web',
      accountScope: 'uid:1',
      token: RecommendationSession().begin(),
    );
    expect(provider.calls, 0);
    expect(page.status, AiFeedStatus.budgetExhausted);
  });

  test('an invalidated generation does not send a request', () async {
    final session = RecommendationSession();
    final token = session.begin();
    session.invalidate();
    final page = await pipeline().rankFeatures(
      features: [f('BV1', 'A', 0)],
      source: 'web',
      accountScope: 'uid:1',
      token: token,
      isCurrent: () => session.isCurrent(token),
    );
    expect(provider.calls, 0);
    expect(page.freshScores, 0);
  });

  test('strict mode keeps candidates the model did not score', () async {
    settings = settings.copyWith(mode: AiRecommendMode.strict);
    provider.handler = (request) async =>
        resultFor(request, only: {'BV1'}, relevanceFor: (_) => 0.95);
    final page = await pipeline().rankFeatures(
      features: [f('BV1', 'A', 0), f('BV2', 'B', 1), f('BV3', 'C', 2)],
      source: 'web',
      accountScope: 'uid:1',
      token: RecommendationSession().begin(),
    );
    expect(page.items.map((e) => e.features.bvid).toSet(), {
      'BV1',
      'BV2',
      'BV3',
    });
    expect(page.strictDropped, 0);
  });

  test(
    'a slow model does not block the first paint and lands in cache',
    () async {
      settings = settings.copyWith(firstPaintBudgetMs: 50);
      provider.handler = (request) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return resultFor(request, relevanceFor: (_) => 0.9);
      };
      final p = pipeline();
      final session = RecommendationSession();
      final page = await p.rankFeatures(
        features: [f('BV1', 'A', 0), f('BV2', 'B', 1)],
        source: 'web',
        accountScope: 'uid:1',
        token: session.begin(),
      );
      expect(page.newRankingReady, isTrue);
      expect(page.freshScores, 0);
      expect(page.status, AiFeedStatus.unavailable);

      await Future<void>.delayed(const Duration(milliseconds: 500));
      final second = await p.rankFeatures(
        features: [f('BV1', 'A', 0), f('BV2', 'B', 1)],
        source: 'web',
        accountScope: 'uid:1',
        token: session.begin(),
      );
      expect(second.cacheHits, 2);
      expect(second.status, AiFeedStatus.cached);
    },
  );

  test('accounts do not share cache or budget', () async {
    final p = pipeline();
    await p.rankFeatures(
      features: [f('BV1', 'A', 0)],
      source: 'web',
      accountScope: 'uid:1',
      token: RecommendationSession().begin(),
    );
    final before = provider.calls;
    final page = await p.rankFeatures(
      features: [f('BV1', 'A', 0)],
      source: 'web',
      accountScope: 'uid:2',
      token: RecommendationSession().begin(),
    );
    expect(provider.calls, before + 1);
    expect(page.cacheHits, 0);
    expect(page.status, AiFeedStatus.active);
  });

  test('feedback updates the local profile and undo removes it', () async {
    final p = pipeline();
    final ok = await p.recordFeedback(
      features: f('BV1', 'Flutter 教程', 0),
      kind: FeedbackKind.more,
      accountScope: 'uid:1',
      modelTopics: const ['Flutter'],
    );
    expect(ok, isTrue);
    final profile = await profiles.read('uid:1');
    expect(profile!.feedbacks.length, 1);
    expect(profile.topics, isNotEmpty);

    expect(await p.undoLastFeedback('uid:1'), isTrue);
    final undone = await profiles.read('uid:1');
    expect(undone!.feedbacks, isEmpty);
    expect(undone.topics, isEmpty);
  });

  test('learning is off unless watch history is explicitly enabled', () async {
    final p = pipeline();
    final signal = WatchSignal(
      bvid: 'BV1',
      title: 'Flutter 教程',
      durationMs: 600000,
      effectiveMs: 500000,
      completed: true,
      at: DateTime(2026, 11, 5),
      accountScope: 'uid:1',
    );
    expect(
      await p.recordWatch(signal: signal, settings: settings),
      isFalse,
    );
    settings = settings.copyWith(useWatchHistory: true);
    expect(
      await p.recordWatch(signal: signal, settings: settings),
      isTrue,
    );
  });
}
