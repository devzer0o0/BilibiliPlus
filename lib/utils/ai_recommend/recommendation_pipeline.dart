// ignore_for_file: prefer_interpolation_to_compose_strings
import 'dart:async';

import 'package:PiliPlus/models/ai_recommend/ai_recommend_settings.dart';
import 'package:PiliPlus/models/ai_recommend/ai_score.dart';
import 'package:PiliPlus/models/ai_recommend/interest_profile.dart';
import 'package:PiliPlus/models/ai_recommend/video_features.dart';
import 'package:PiliPlus/models/model_rec_video_item.dart';
import 'package:PiliPlus/utils/ai_recommend/ai_provider.dart';
import 'package:PiliPlus/utils/ai_recommend/ai_score_cache.dart';
import 'package:PiliPlus/utils/ai_recommend/ai_usage.dart';
import 'package:PiliPlus/utils/ai_recommend/interest_profile_repository.dart';
import 'package:PiliPlus/utils/ai_recommend/interest_profile_service.dart';
import 'package:PiliPlus/utils/ai_recommend/recommendation_ranker.dart';
import 'package:PiliPlus/utils/security/secret_store.dart';

enum AiFeedStatus {
  off('AI 已关闭'),
  active('AI 已生效'),
  cached('使用缓存'),
  localRules('当前使用本地规则'),
  unavailable('AI 暂不可用'),
  budgetExhausted('已达到请求预算');

  const AiFeedStatus(this.label);

  final String label;
}

class RecommendationToken {
  RecommendationToken(this.generation);

  final int generation;
  bool cancelled = false;
}

/// Increments on every refresh, keyword change, account switch, profile reset
/// or page disposal. A response whose token is no longer current must not be
/// applied or written back.
class RecommendationSession {
  int _generation = 0;

  RecommendationToken begin() {
    _generation++;
    return RecommendationToken(_generation);
  }

  void invalidate() {
    _generation++;
  }

  bool isCurrent(RecommendationToken token) =>
      !token.cancelled && token.generation == _generation;
}

class AiRankedPage {
  const AiRankedPage({
    required this.items,
    required this.folded,
    required this.status,
    required this.statusDetail,
    required this.originalCount,
    required this.keptCount,
    required this.strictDropped,
    required this.exploreCount,
    required this.freshScores,
    required this.cacheHits,
    required this.requestsToday,
    required this.waitMs,
    this.newRankingReady = false,
    this.scores = const {},
    this.interestLabels = const {},
  });

  final List<RankedRecommendation> items;
  final List<RankedRecommendation> folded;
  final AiFeedStatus status;
  final String statusDetail;
  final int originalCount;
  final int keptCount;
  final int strictDropped;
  final int exploreCount;
  final int freshScores;
  final int cacheHits;
  final int requestsToday;
  final int waitMs;
  final bool newRankingReady;
  final Map<String, AiCandidateScore> scores;
  final Map<String, String> interestLabels;

  int get foldedCount => folded.length;
}

/// Orchestrates cache lookup, model requests, budget/circuit limits and local
/// ranking. It never talks to Bilibili's network layer and never writes Hive
/// outside the stores passed in.
class AiRecommendationPipeline {
  AiRecommendationPipeline({
    required this.settingsLoader,
    required this.profileStore,
    required this.cache,
    required this.usage,
    required this.secrets,
    required this.providerFactory,
    this.ranker = const RecommendationRanker(),
    DateTime Function()? clock,
    Future<void> Function()? onProfileWrite,
  }) : clock = clock ?? DateTime.now,
       onProfileWrite = onProfileWrite ?? _noop;

  final Future<AiRecommendSettings> Function() settingsLoader;
  final InterestProfileStore profileStore;
  final AiScoreCache cache;
  final AiUsageStore usage;
  final SecretStore secrets;
  final AiProvider Function(AiProviderConfig config) providerFactory;
  final RecommendationRanker ranker;
  final DateTime Function() clock;
  final Future<void> Function() onProfileWrite;

  static Future<void> _noop() async {}

  /// Cache-only scoring lookup used by tests and by the late-response path.
  Future<Map<String, AiCandidateScore>> cachedScores({
    required List<VideoFeatures> features,
    required String source,
    required String accountScope,
    required AiRecommendSettings settings,
  }) async {
    final result = <String, AiCandidateScore>{};
    final fingerprint = AiScoreCacheKey.settingsFingerprint(
      wantTags: settings.wantTags,
      avoidTags: settings.avoidTags,
      description: settings.interestDescription,
    );
    final providerFp = settings.hasModel
        ? AiProviderConfig(
            baseUrl: settings.baseUrl,
            model: settings.model,
          ).fingerprint
        : 'none';
    for (final feature in features) {
      final key = AiScoreCacheKey.build(
        accountScope: accountScope,
        source: source,
        features: feature,
        settingsFingerprint: fingerprint,
        providerFingerprint: providerFp,
      );
      final entry = await cache.read(key);
      if (entry != null) result[feature.bvid] = entry.score;
    }
    return result;
  }

  Future<AiRankedPage> rankPage({
    required List<BaseRcmdVideoItemModel> models,
    required String source,
    required String accountScope,
    required RecommendationToken token,
    bool Function()? isCurrent,
    bool allowFolding = true,
    Map<String, int> lastShownAtMs = const {},
    void Function()? onLateRankingReady,
    bool cacheOnly = false,
  }) {
    final features = featuresOf(models, source);
    return rankFeatures(
      features: features,
      source: source,
      accountScope: accountScope,
      token: token,
      isCurrent: isCurrent,
      allowFolding: allowFolding,
      lastShownAtMs: lastShownAtMs,
      onLateRankingReady: onLateRankingReady,
      cacheOnly: cacheOnly,
    );
  }

  Future<AiRankedPage> rankFeatures({
    required List<VideoFeatures> features,
    required String source,
    required String accountScope,
    required RecommendationToken token,
    bool Function()? isCurrent,
    bool allowFolding = true,
    Map<String, int> lastShownAtMs = const {},
    void Function()? onLateRankingReady,
    bool cacheOnly = false,
  }) async {
    final started = clock();
    final settings = await settingsLoader();
    final deduped = _dedupe(features);
    if (!settings.enabled) {
      return AiRankedPage(
        items: [
          for (var i = 0; i < deduped.length; i++)
            RankedRecommendation(
              features: deduped[i],
              score: 1 - i / deduped.length,
              reason: '保留 B 站原排序',
            ),
        ],
        folded: const [],
        status: AiFeedStatus.off,
        statusDetail: 'AI 推荐筛选已关闭',
        originalCount: features.length,
        keptCount: deduped.length,
        strictDropped: 0,
        exploreCount: 0,
        freshScores: 0,
        cacheHits: 0,
        requestsToday: 0,
        waitMs: 0,
      );
    }

    final profile = await profileStore.read(accountScope);
    final interestLabels = <String, String>{};
    if (profile != null) {
      for (final topic in profile.topics.values) {
        interestLabels[topic.id] = topic.label;
      }
    }
    for (final tag in settings.wantTags) {
      interestLabels[InterestProfile.topicId(tag)] = tag;
    }
    for (final tag in settings.avoidTags) {
      interestLabels[InterestProfile.topicId(tag)] = tag;
    }

    final scores = <String, AiCandidateScore>{};
    var cacheHits = 0;
    final fingerprint = AiScoreCacheKey.settingsFingerprint(
      wantTags: settings.wantTags,
      avoidTags: settings.avoidTags,
      description: settings.interestDescription,
    );
    final providerConfig = AiProviderConfig(
      baseUrl: settings.baseUrl,
      model: settings.model,
      timeoutMs: settings.requestTimeoutMs,
      jsonMode: settings.jsonMode,
      allowInsecureHttp: settings.allowInsecureHttp,
    );
    for (final feature in deduped) {
      final key = AiScoreCacheKey.build(
        accountScope: accountScope,
        source: source,
        features: feature,
        settingsFingerprint: fingerprint,
        providerFingerprint: settings.hasModel
            ? providerConfig.fingerprint
            : 'none',
      );
      final entry = await cache.read(key);
      if (entry != null) {
        scores[feature.bvid] = entry.score;
        cacheHits++;
      }
    }

    var freshScores = 0;
    var requestsToday = 0;
    var status = AiFeedStatus.localRules;
    var statusDetail = settings.hasModel
        ? '本次刷新暂时保留本地排序'
        : '未配置模型服务，只使用关键词与本地画像';
    var newRankingReady = false;
    var waitMs = 0;
    AiProvider? provider;

    if (settings.hasModel && !cacheOnly) {
      final today = clock();
      final snapshot = await usage.read(accountScope, today);
      requestsToday = snapshot.requests;
      if (snapshot.requests >= settings.dailyRequestBudget) {
        status = AiFeedStatus.budgetExhausted;
        statusDetail =
            '今日已用 ' +
            snapshot.requests.toString() +
            '/' +
            settings.dailyRequestBudget.toString() +
            ' 次请求';
      } else {
        try {
          provider = providerFactory(providerConfig);
        } on Object catch (e) {
          status = AiFeedStatus.unavailable;
          statusDetail = _friendlyFailure(e);
        }
      }
    }

    if (provider != null) {
      final unscored = deduped
          .where(
            (f) =>
                f.bvid.isNotEmpty &&
                !scores.containsKey(f.bvid) &&
                f.title.isNotEmpty,
          )
          .toList();
      final batchSize = settings.batchSize;
      final maxBatches = settings.maxBatchesPerRefresh;
      final interests = _interestRefs(settings, profile, positive: true);
      final avoid = _interestRefs(settings, profile, positive: false);
      final deadline = started.add(
        Duration(milliseconds: settings.firstPaintBudgetMs),
      );
      var failures = 0;

      for (var batch = 0; batch < maxBatches; batch++) {
        if (isCurrent != null && !isCurrent()) break;
        if (token.cancelled) break;
        final slice = unscored
            .where((f) => !scores.containsKey(f.bvid))
            .take(batchSize)
            .toList();
        if (slice.isEmpty) break;
        final currentUsage = await usage.read(accountScope, clock());
        requestsToday = currentUsage.requests;
        if (currentUsage.requests >= settings.dailyRequestBudget) {
          status = AiFeedStatus.budgetExhausted;
          statusDetail = '今日请求预算已用完，剩余候选使用本地排序';
          break;
        }

        final envelopes = [
          for (var i = 0; i < slice.length; i++)
            AiCandidateEnvelope(
              requestId: requestIdForIndex(i),
              features: slice[i],
            ),
        ];
        final request = AiBatchRequest(
          candidates: envelopes,
          interests: interests,
          avoidInterests: avoid,
          interestDescription: settings.interestDescription,
        );

        await usage.add(accountScope, clock(), requests: 1);
        requestsToday++;
        final requestStarted = clock();
        final future = provider.score(request);
        final remaining = deadline.difference(clock());
        if (remaining <= Duration.zero) {
          newRankingReady = true;
          _acceptLate(
            future,
            request: request,
            accountScope: accountScope,
            source: source,
            settings: settings,
            fingerprint: fingerprint,
            providerConfig: providerConfig,
            scores: scores,
            onLateRankingReady: onLateRankingReady,
          );
          break;
        }
        try {
          final result = await future.timeout(remaining);
          if (token.cancelled || (isCurrent != null && !isCurrent())) break;
          final keys = _writeScores(
            result.scores.scoresByBvid,
            request: request,
            accountScope: accountScope,
            source: source,
            settings: settings,
            fingerprint: fingerprint,
            providerConfig: providerConfig,
          );
          await Future.wait(keys);
          result.scores.scoresByBvid.forEach((bvid, score) {
            scores[bvid] = score;
          });
          freshScores += result.scores.scoresByBvid.length;
          if (result.promptTokens + result.completionTokens > 0) {
            await usage.add(
              accountScope,
              clock(),
              promptTokens: result.promptTokens,
              completionTokens: result.completionTokens,
            );
          }
          await usage.add(accountScope, clock());
          status = AiFeedStatus.active;
          statusDetail = '本次刷新由 AI 参与排序';
          waitMs += clock().difference(requestStarted).inMilliseconds;
          if (result.scores.scoresByBvid.length < slice.length) {
            statusDetail = 'AI 只评分了部分候选，其余保留本地排序';
          }
        } on TimeoutException {
          newRankingReady = true;
          _acceptLate(
            future,
            request: request,
            accountScope: accountScope,
            source: source,
            settings: settings,
            fingerprint: fingerprint,
            providerConfig: providerConfig,
            scores: scores,
            onLateRankingReady: onLateRankingReady,
          );
          status = scores.isEmpty
              ? AiFeedStatus.localRules
              : AiFeedStatus.cached;
          statusDetail = scores.isEmpty
              ? '模型仍在后台评分，先保留本地排序；结果就绪后可刷新使用'
              : '模型响应较慢，本次沿用缓存评分；新结果会用于下一次刷新';
          waitMs += settings.firstPaintBudgetMs;
          break;
        } on AiProviderException catch (e) {
          failures++;
          status = e.kind == AiProviderFailure.rateLimit
              ? AiFeedStatus.unavailable
              : scores.isEmpty
              ? AiFeedStatus.unavailable
              : AiFeedStatus.cached;
          statusDetail = _friendlyFailure(e);
          if (e.kind == AiProviderFailure.auth ||
              e.kind == AiProviderFailure.notConfigured) {
            break;
          }
          if (failures >= 2) break;
        } on Object catch (e) {
          failures++;
          status = scores.isEmpty
              ? AiFeedStatus.unavailable
              : AiFeedStatus.cached;
          statusDetail = '模型评分失败，已降级：' + _friendlyFailure(e);
          if (failures >= 2) break;
        }
      }

      if (freshScores == 0 &&
          scores.isNotEmpty &&
          status == AiFeedStatus.localRules) {
        status = AiFeedStatus.cached;
        statusDetail = '本次评分来自 24 小时缓存';
      }
      if (freshScores > 0) {
        status = AiFeedStatus.active;
      }
    }

    final ranked = ranker.rank(
      candidates: deduped,
      settings: settings,
      profile: profile,
      scores: scores,
      lastShownAtMs: lastShownAtMs,
      interestLabels: interestLabels,
      now: clock(),
      seed: clock().millisecondsSinceEpoch ~/ 60000,
      allowFolding: allowFolding,
    );

    var finalStatus = status;
    if (!settings.enabled) {
      finalStatus = AiFeedStatus.off;
    } else if (freshScores > 0) {
      finalStatus = AiFeedStatus.active;
    } else if (scores.isNotEmpty) {
      finalStatus = AiFeedStatus.cached;
    } else if (status == AiFeedStatus.budgetExhausted) {
      finalStatus = AiFeedStatus.budgetExhausted;
    } else if (status == AiFeedStatus.unavailable) {
      finalStatus = AiFeedStatus.unavailable;
    } else {
      finalStatus = AiFeedStatus.localRules;
    }

    return AiRankedPage(
      items: ranked.items,
      folded: ranked.folded,
      status: finalStatus,
      statusDetail: ranked.dropReasons.isEmpty
          ? statusDetail
          : statusDetail + '；' + ranked.dropReasons.join('，'),
      originalCount: features.length,
      keptCount: ranked.items.length,
      strictDropped: ranked.strictDropped,
      exploreCount: ranked.exploreCount,
      freshScores: freshScores,
      cacheHits: cacheHits,
      requestsToday: requestsToday,
      waitMs: waitMs,
      newRankingReady: newRankingReady,
      scores: scores,
      interestLabels: interestLabels,
    );
  }

  void _acceptLate(
    Future<AiProviderResult> future, {
    required AiBatchRequest request,
    required String accountScope,
    required String source,
    required AiRecommendSettings settings,
    required String fingerprint,
    required AiProviderConfig providerConfig,
    required Map<String, AiCandidateScore> scores,
    void Function()? onLateRankingReady,
  }) {
    unawaited(
      future
          .then((result) async {
            await Future.wait(
              _writeScores(
                result.scores.scoresByBvid,
                request: request,
                accountScope: accountScope,
                source: source,
                settings: settings,
                fingerprint: fingerprint,
                providerConfig: providerConfig,
              ),
            );
            if (result.promptTokens + result.completionTokens > 0) {
              await usage.add(
                accountScope,
                clock(),
                promptTokens: result.promptTokens,
                completionTokens: result.completionTokens,
              );
            }
            onLateRankingReady?.call();
          })
          .catchError((Object _) {
            // Late failures stay late: they must not replace a page already shown.
          }),
    );
  }

  List<Future<void>> _writeScores(
    Map<String, AiCandidateScore> scoresByBvid, {
    required AiBatchRequest request,
    required String accountScope,
    required String source,
    required AiRecommendSettings settings,
    required String fingerprint,
    required AiProviderConfig providerConfig,
  }) {
    final now = clock().millisecondsSinceEpoch;
    final byBvid = {
      for (final c in request.candidates) c.features.bvid: c.features,
    };
    final writes = <Future<void>>[];
    scoresByBvid.forEach((bvid, score) {
      final features = byBvid[bvid];
      if (features == null) return;
      final key = AiScoreCacheKey.build(
        accountScope: accountScope,
        source: source,
        features: features,
        settingsFingerprint: fingerprint,
        providerFingerprint: providerConfig.fingerprint,
      );
      writes.add(
        cache.write(key, AiScoreCacheEntry(score: score, cachedAtMs: now)),
      );
    });
    return writes;
  }

  List<AiInterestRef> _interestRefs(
    AiRecommendSettings settings,
    InterestProfile? profile, {
    required bool positive,
  }) {
    final refs = <String, AiInterestRef>{};
    for (final tag in positive ? settings.wantTags : settings.avoidTags) {
      final id = InterestProfile.topicId(tag);
      refs[id] = AiInterestRef(
        id: id,
        label: tag,
        weight: positive ? 0.8 : -0.8,
      );
    }
    if (profile != null) {
      final topics = profile.visibleTopics;
      for (final topic in topics) {
        final isPositive = topic.score > 0;
        if (isPositive != positive) continue;
        refs.putIfAbsent(
          topic.id,
          () => AiInterestRef(
            id: topic.id,
            label: topic.label,
            weight: topic.score,
          ),
        );
        if (refs.length >= 16) break;
      }
    }
    return refs.values.toList();
  }

  Future<InterestProfile?> profileFor(String accountScope) =>
      profileStore.read(accountScope);

  Future<void> deleteTopic(String accountScope, String topicId) async {
    final profile = await profileStore.read(accountScope);
    if (profile == null) return;
    await profileStore.write(
      InterestProfileService.removeTopic(profile, topicId),
    );
    await onProfileWrite();
  }

  Future<void> resetProfile(String accountScope) async {
    await profileStore.delete(accountScope);
    await onProfileWrite();
  }

  Future<void> clearScores() => cache.clear();

  Future<bool> recordFeedback({
    required VideoFeatures features,
    required FeedbackKind kind,
    required String accountScope,
    List<String> modelTopics = const [],
  }) async {
    final settings = await settingsLoader();
    if (!settings.enabled) return false;
    final profile =
        await profileStore.read(accountScope) ??
        InterestProfile.empty(accountScope);
    final next = InterestProfileService.applyFeedback(
      profile,
      features,
      kind,
      settings,
      modelTopics: modelTopics,
    );
    await profileStore.write(next);
    await onProfileWrite();
    return true;
  }

  Future<bool> undoLastFeedback(String accountScope) async {
    final settings = await settingsLoader();
    final profile = await profileStore.read(accountScope);
    if (profile == null || profile.feedbacks.isEmpty) return false;
    await profileStore.write(
      InterestProfileService.undoLastFeedback(profile, settings),
    );
    await onProfileWrite();
    return true;
  }

  Future<bool> recordWatch({
    required WatchSignal signal,
    required AiRecommendSettings settings,
    List<String> modelTopics = const [],
  }) async {
    if (!settings.enabled ||
        !settings.useWatchHistory ||
        settings.pausedLearning) {
      return false;
    }
    if (signal.accountScope == AccountScope.anonymous) return false;
    final profile =
        await profileStore.read(signal.accountScope) ??
        InterestProfile.empty(signal.accountScope);
    final next = InterestProfileService.applyWatch(
      profile,
      signal,
      settings,
      modelTopics: modelTopics,
    );
    if (identical(next, profile)) return false;
    await profileStore.write(next);
    await onProfileWrite();
    return true;
  }

  static List<VideoFeatures> featuresOf(
    List<BaseRcmdVideoItemModel> models,
    String source,
  ) => _dedupe([
    for (var i = 0; i < models.length; i++)
      VideoFeatures.fromRecommendation(models[i], index: i, source: source),
  ]);

  static List<VideoFeatures> _dedupe(List<VideoFeatures> features) {
    final seen = <String>{};
    final result = <VideoFeatures>[];
    for (final feature in features) {
      if (feature.bvid.trim().isEmpty) continue;
      if (seen.add(feature.bvid)) result.add(feature);
    }
    return result;
  }

  static String _friendlyFailure(Object error) {
    if (error is AiProviderException) {
      return switch (error.kind) {
        AiProviderFailure.auth => '模型服务鉴权失败，请检查 API Key',
        AiProviderFailure.rateLimit => '模型服务限流，稍后会自动重试',
        AiProviderFailure.timeout => '模型服务超时',
        AiProviderFailure.network => '无法连接模型服务',
        AiProviderFailure.tls => '模型服务证书校验失败',
        AiProviderFailure.server => '模型服务暂时不可用',
        AiProviderFailure.redirect => '模型服务返回了重定向，已拒绝',
        AiProviderFailure.notConfigured => '模型服务配置不完整',
        AiProviderFailure.invalidResponse => '模型返回格式无法识别',
        AiProviderFailure.cancelled => '模型请求已取消',
        AiProviderFailure.requestTooLarge => '本批候选过大',
      };
    }
    return '模型评分失败';
  }
}
