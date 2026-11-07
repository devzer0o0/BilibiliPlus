import 'dart:convert';

import 'package:flutter/foundation.dart';

/// How AI participates in the recommendation feed.
///
/// Both modes run *after* the existing hard filters (advertising, blacklist,
/// title regexp, age, duration, like ratio). Nothing here can re-admit an item
/// those rules already removed.
enum AiRecommendMode {
  preference('偏好排序'),
  strict('严格精选');

  const AiRecommendMode(this.label);

  final String label;

  static AiRecommendMode fromStored(Object? value) {
    final name = value is String ? value : null;
    for (final mode in values) {
      if (mode.name == name) return mode;
    }
    return preference;
  }
}

/// User-facing, non-secret configuration for AI recommendation filtering.
///
/// This object is deliberately free of Hive and Flutter bindings so ranking
/// and request construction can be tested with plain values. Secrets (the API
/// key) live in the secret store and are never part of [toMap], which is also
/// what the backup registry is allowed to persist.
@immutable
class AiRecommendSettings {
  const AiRecommendSettings({
    this.enabled = false,
    this.mode = AiRecommendMode.preference,
    this.wantTags = const [],
    this.avoidTags = const [],
    this.interestDescription = '',
    this.useWatchHistory = false,
    this.pausedLearning = false,
    this.baseUrl = '',
    this.model = '',
    this.providerPreset = 'custom',
    this.dailyRequestBudget = 100,
    this.explorationRatio = 0.2,
    this.profileRetentionDays = 90,
    this.strictThreshold = 0.55,
    this.batchSize = 20,
    this.maxBatchesPerRefresh = 2,
    this.requestTimeoutMs = defaultRequestTimeoutMs,
    this.firstPaintBudgetMs = 2000,
    this.jsonMode = true,
    this.allowInsecureHttp = false,
  });

  static const AiRecommendSettings defaults = AiRecommendSettings();

  /// Master switch. Off means no requests, no learning and the original feed.
  final bool enabled;

  final AiRecommendMode mode;

  /// Explicit "want to see" phrases. Empty is different from "no opinion":
  /// when both lists are empty the ranker keeps the upstream order.
  final List<String> wantTags;

  /// Soft "see less" phrases. These never hide content the user's hard rules
  /// allow; strict mode and folding are explained in the UI.
  final List<String> avoidTags;

  /// Optional natural-language interest description, sent to the model.
  final String interestDescription;

  /// Off by default: history is only read after an explicit opt-in.
  final bool useWatchHistory;

  /// Stops new learning while keeping existing profile data readable.
  final bool pausedLearning;

  final String baseUrl;
  final String model;
  final String providerPreset;
  final int dailyRequestBudget;
  final double explorationRatio;
  final int profileRetentionDays;
  final double strictThreshold;
  final int batchSize;
  final int maxBatchesPerRefresh;
  final int requestTimeoutMs;
  final int firstPaintBudgetMs;

  /// Whether to ask for an OpenAI-compatible JSON object response format.
  /// Providers that reject it can turn it off; the client still validates
  /// strictly and never trusts the response.
  final bool jsonMode;

  /// Explicit opt-in for an HTTP model server on a private network. The API key
  /// is sent in clear text on that hop; public HTTP hosts remain rejected.
  final bool allowInsecureHttp;

  /// Upper bound accepted for [dailyRequestBudget]. The gate only stops new
  /// requests, so this exists to catch typos (a stray zero) rather than to
  /// mirror a provider limit.
  static const int maxDailyRequestBudget = 100000;

  /// Whole-request budget for one model call: connect, send and receive all
  /// share it. Thirty seconds covers a cold call to a reasoning model; the
  /// previous 6 s default reported such a provider as “连接超时”.
  ///
  /// This is app policy rather than a preference: no screen writes it, so a
  /// stored value left behind by the old default is ignored instead of
  /// honoured (`copyWith` still overrides it for the prefetch paths).
  static const int defaultRequestTimeoutMs = 30000;

  bool get hasModel => baseUrl.trim().isNotEmpty && model.trim().isNotEmpty;

  bool get hasExplicitPreference =>
      wantTags.isNotEmpty ||
      avoidTags.isNotEmpty ||
      interestDescription.trim().isNotEmpty;

  static List<String> parseTags(Object? value) {
    if (value is List) {
      return _cleanTags(value.map((e) => e?.toString() ?? ''));
    }
    if (value is String) {
      return _cleanTags(value.split(RegExp(r'[\n,，;；]')));
    }
    return const [];
  }

  static List<String> _cleanTags(Iterable<String> raw) {
    final seen = <String>{};
    final result = <String>[];
    for (final item in raw) {
      final tag = item.trim();
      if (tag.isEmpty) continue;
      final clipped = tag.length > 32 ? tag.substring(0, 32) : tag;
      final key = clipped.toLowerCase();
      if (seen.add(key)) result.add(clipped);
      if (result.length >= 20) break;
    }
    return result;
  }

  static String joinTags(List<String> tags) => tags.join('\n');

  /// Tolerant reader: a missing or wrong-typed value falls back to the default
  /// for that field, never to a partially built configuration.
  factory AiRecommendSettings.fromMap(Map<String, dynamic> map) {
    T pick<T>(String key, T fallback) {
      final value = map[key];
      if (value is T) return value;
      return fallback;
    }

    int intIn(String key, int fallback, int min, int max) =>
        pick<int>(key, fallback).clamp(min, max);

    double doubleIn(String key, double fallback, double min, double max) {
      final raw = map[key];
      final value = raw is num ? raw.toDouble() : fallback;
      if (value.isNaN || value.isInfinite) return fallback;
      return value.clamp(min, max);
    }

    final description = pick<String>('interestDescription', '').trim();
    return AiRecommendSettings(
      enabled: pick<bool>('enabled', false),
      mode: AiRecommendMode.fromStored(map['mode']),
      wantTags: parseTags(map['wantTags']),
      avoidTags: parseTags(map['avoidTags']),
      interestDescription: description.length > 500
          ? description.substring(0, 500)
          : description,
      useWatchHistory: pick<bool>('useWatchHistory', false),
      pausedLearning: pick<bool>('pausedLearning', false),
      baseUrl: pick<String>('baseUrl', '').trim(),
      model: pick<String>('model', '').trim(),
      providerPreset: pick<String>('providerPreset', 'custom'),
      dailyRequestBudget: intIn(
        'dailyRequestBudget',
        100,
        0,
        maxDailyRequestBudget,
      ),
      explorationRatio: doubleIn('explorationRatio', 0.2, 0, 0.5),
      profileRetentionDays: intIn('profileRetentionDays', 90, 7, 365),
      strictThreshold: doubleIn('strictThreshold', 0.55, 0.3, 0.95),
      batchSize: intIn('batchSize', 20, 5, 40),
      maxBatchesPerRefresh: intIn('maxBatchesPerRefresh', 2, 1, 3),
      requestTimeoutMs: defaultRequestTimeoutMs,
      // Measured against reasoning-capable models: a cold request commonly
      // takes 1.5 s, so 800 ms declared every such refresh unavailable before
      // the (successful) response landed. Two seconds keeps the first paint
      // honest without hiding a genuinely slow service.
      firstPaintBudgetMs: intIn('firstPaintBudgetMs', 2000, 2000, 5000),
      jsonMode: pick<bool>('jsonMode', true),
      allowInsecureHttp: pick<bool>('allowInsecureHttp', false),
    );
  }

  /// The portable, explicitly configured subset. Never contains a key,
  /// endpoint credential or inferred profile.
  Map<String, dynamic> toMap() => {
    'enabled': enabled,
    'mode': mode.name,
    'wantTags': wantTags,
    'avoidTags': avoidTags,
    'interestDescription': interestDescription,
    'useWatchHistory': useWatchHistory,
    'pausedLearning': pausedLearning,
    'baseUrl': baseUrl,
    'model': model,
    'providerPreset': providerPreset,
    'dailyRequestBudget': dailyRequestBudget,
    'explorationRatio': explorationRatio,
    'profileRetentionDays': profileRetentionDays,
    'strictThreshold': strictThreshold,
    'batchSize': batchSize,
    'maxBatchesPerRefresh': maxBatchesPerRefresh,
    'requestTimeoutMs': requestTimeoutMs,
    'firstPaintBudgetMs': firstPaintBudgetMs,
    'jsonMode': jsonMode,
    'allowInsecureHttp': allowInsecureHttp,
  };

  String toJson() => jsonEncode(toMap());

  AiRecommendSettings copyWith({
    bool? enabled,
    AiRecommendMode? mode,
    List<String>? wantTags,
    List<String>? avoidTags,
    String? interestDescription,
    bool? useWatchHistory,
    bool? pausedLearning,
    String? baseUrl,
    String? model,
    String? providerPreset,
    int? dailyRequestBudget,
    double? explorationRatio,
    int? profileRetentionDays,
    double? strictThreshold,
    int? batchSize,
    int? maxBatchesPerRefresh,
    int? requestTimeoutMs,
    int? firstPaintBudgetMs,
    bool? jsonMode,
    bool? allowInsecureHttp,
  }) => AiRecommendSettings(
    enabled: enabled ?? this.enabled,
    mode: mode ?? this.mode,
    wantTags: wantTags ?? this.wantTags,
    avoidTags: avoidTags ?? this.avoidTags,
    interestDescription: interestDescription ?? this.interestDescription,
    useWatchHistory: useWatchHistory ?? this.useWatchHistory,
    pausedLearning: pausedLearning ?? this.pausedLearning,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    providerPreset: providerPreset ?? this.providerPreset,
    dailyRequestBudget: dailyRequestBudget ?? this.dailyRequestBudget,
    explorationRatio: explorationRatio ?? this.explorationRatio,
    profileRetentionDays: profileRetentionDays ?? this.profileRetentionDays,
    strictThreshold: strictThreshold ?? this.strictThreshold,
    batchSize: batchSize ?? this.batchSize,
    maxBatchesPerRefresh: maxBatchesPerRefresh ?? this.maxBatchesPerRefresh,
    requestTimeoutMs: requestTimeoutMs ?? this.requestTimeoutMs,
    firstPaintBudgetMs: firstPaintBudgetMs ?? this.firstPaintBudgetMs,
    jsonMode: jsonMode ?? this.jsonMode,
    allowInsecureHttp: allowInsecureHttp ?? this.allowInsecureHttp,
  );
}
