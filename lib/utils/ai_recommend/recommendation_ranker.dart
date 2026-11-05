// ignore_for_file: prefer_interpolation_to_compose_strings
import 'dart:math' as math;

import 'package:PiliPlus/models/ai_recommend/ai_recommend_settings.dart';
import 'package:PiliPlus/models/ai_recommend/ai_score.dart';
import 'package:PiliPlus/models/ai_recommend/interest_profile.dart';
import 'package:PiliPlus/models/ai_recommend/video_features.dart';
import 'package:flutter/foundation.dart';

@immutable
class RankedRecommendation {
  const RankedRecommendation({
    required this.features,
    required this.score,
    required this.reason,
    this.folded = false,
    this.explored = false,
  });

  final VideoFeatures features;
  final double score;
  final String reason;
  final bool folded;
  final bool explored;
}

class RecommendationRankResult {
  const RecommendationRankResult({
    required this.items,
    required this.folded,
    required this.strictDropped,
    required this.scoredCount,
    required this.exploreCount,
    required this.usedModel,
    this.dropReasons = const [],
  });

  final List<RankedRecommendation> items;
  final List<RankedRecommendation> folded;
  final int strictDropped;
  final int scoredCount;
  final int exploreCount;
  final bool usedModel;
  final List<String> dropReasons;
}

class RecommendationRanker {
  const RecommendationRanker();

  static const double wSemantic = 0.40;
  static const double wLocal = 0.30;
  static const double wExplicit = 0.28;
  static const double wFreshness = 0.05;
  static const double wUpstream = 0.06;
  static const double wAuthor = 0.04;
  static const double seenPenalty = 0.10;
  static const double neutral = 0.5;

  RecommendationRankResult rank({
    required List<VideoFeatures> candidates,
    required AiRecommendSettings settings,
    InterestProfile? profile,
    Map<String, AiCandidateScore> scores = const {},
    Map<String, int> lastShownAtMs = const {},
    Map<String, String> interestLabels = const {},
    DateTime? now,
    int seed = 0,
    bool allowFolding = true,
  }) {
    if (candidates.isEmpty) {
      return const RecommendationRankResult(
        items: [],
        folded: [],
        strictDropped: 0,
        scoredCount: 0,
        exploreCount: 0,
        usedModel: false,
      );
    }
    final clock = now ?? DateTime.now();
    final usedModel = scores.isNotEmpty;
    final scored = <_ScoredItem>[];

    for (var index = 0; index < candidates.length; index++) {
      final features = candidates[index];
      final model = scores[features.bvid];
      final text = features.matchText;
      final wantTag = _firstMatch(settings.wantTags, text);
      final avoidTag = _firstMatch(settings.avoidTags, text);
      final localMatch =
          profile?.matchText(
            text,
            extraPositive: settings.wantTags,
            extraNegative: settings.avoidTags,
          ) ??
          0.0;

      double weighted = 0;
      double weightSum = 0;
      if (model != null) {
        weighted += model.effectiveRelevance * wSemantic;
        weightSum += wSemantic;
      }
      final hasLocal =
          (profile != null && profile.topics.isNotEmpty) ||
          settings.wantTags.isNotEmpty ||
          settings.avoidTags.isNotEmpty;
      if (hasLocal) {
        weighted += ((localMatch + 1) / 2).clamp(0.0, 1.0) * wLocal;
        weightSum += wLocal;
        weighted += _explicitValue(wantTag, avoidTag) * wExplicit;
        weightSum += wExplicit;
      }
      if (features.pubdate != null && features.pubdate! > 0) {
        final days =
            (clock.millisecondsSinceEpoch ~/ 1000 - features.pubdate!) / 86400;
        final freshness = math.exp(-math.max(0, days) / 14);
        weighted += freshness * wFreshness;
        weightSum += wFreshness;
      }
      final authorScore = profile?.authorScore(features.ownerMid) ?? 0;
      if (authorScore != 0) {
        weighted += ((authorScore + 1) / 2) * wAuthor;
        weightSum += wAuthor;
      }
      final upstream = candidates.length <= 1
          ? 1.0
          : 1 - index / (candidates.length - 1);
      weighted += upstream * wUpstream;
      weightSum += wUpstream;

      var value = weightSum == 0 ? neutral : weighted / weightSum;
      final lastShown = lastShownAtMs[features.bvid];
      if (lastShown != null &&
          clock.millisecondsSinceEpoch - lastShown <
              const Duration(hours: 12).inMilliseconds) {
        value -= seenPenalty;
      }
      if (features.isFollowed) value += 0.03;
      final exploratory = _isExploration(features.bvid, seed);
      if (exploratory) value += 0.02;
      value = value.clamp(0.0, 1.0);

      final avoidWeight = profile == null ? 0.0 : _avoidWeight(profile, text);
      final fold =
          allowFolding &&
          !features.isFollowed &&
          !usedModel &&
          ((avoidTag != null && value < 0.55) ||
              (avoidWeight <= -0.4 && value < 0.5));

      scored.add(
        _ScoredItem(
          features: features,
          score: value,
          model: model,
          wantTag: wantTag,
          avoidTag: avoidTag,
          localMatch: localMatch,
          avoidWeight: avoidWeight,
          exploratory: exploratory,
          fold: fold,
        ),
      );
    }

    final visible = <_ScoredItem>[];
    final folded = <_ScoredItem>[];
    for (final item in scored) {
      if (item.fold) {
        folded.add(item);
      } else {
        visible.add(item);
      }
    }

    final kept = <_ScoredItem>[];
    var strictDropped = 0;
    final dropReasons = <String>[];
    if (settings.mode == AiRecommendMode.strict && usedModel) {
      for (final item in visible) {
        final relevance = item.model?.effectiveRelevance;
        if (item.features.isFollowed ||
            relevance == null ||
            relevance >= settings.strictThreshold) {
          kept.add(item);
        } else {
          strictDropped++;
        }
      }
      if (strictDropped > 0) {
        dropReasons.add(
          '相关性低于 ' +
              (settings.strictThreshold * 100).round().toString() +
              '% 的有 ' +
              strictDropped.toString() +
              ' 条',
        );
      }
    } else {
      kept.addAll(visible);
    }

    kept.sort((a, b) {
      final strictRank = settings.mode == AiRecommendMode.strict
          ? _knownRank(b).compareTo(_knownRank(a))
          : 0;
      if (strictRank != 0) return strictRank;
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return a.features.upstreamIndex.compareTo(b.features.upstreamIndex);
    });

    _diversify(kept);
    final exploreCount = _applyExploration(
      kept,
      ratio: settings.explorationRatio,
      seed: seed,
    );

    final labels = <String, String>{...interestLabels};
    final items = kept.map((item) {
      final reason = _reasonFor(item, settings, profile, labels, usedModel);
      return RankedRecommendation(
        features: item.features,
        score: item.score,
        reason: reason,
        explored: item.exploratory,
      );
    }).toList();

    final foldedItems = folded.map((item) {
      final reason = item.avoidTag != null
          ? '已折叠：匹配少看「' + item.avoidTag! + '」'
          : '已折叠：与少看主题相关';
      return RankedRecommendation(
        features: item.features,
        score: item.score,
        reason: reason,
        folded: true,
      );
    }).toList();

    return RecommendationRankResult(
      items: items,
      folded: foldedItems,
      strictDropped: strictDropped,
      scoredCount: visible.where((i) => i.model != null).length,
      exploreCount: exploreCount,
      usedModel: usedModel,
      dropReasons: dropReasons,
    );
  }

  static int _knownRank(_ScoredItem item) => item.model == null ? 0 : 1;

  static double _explicitValue(String? want, String? avoid) {
    if (want != null && avoid != null) return 0.25;
    if (want != null) return 1.0;
    if (avoid != null) return 0.0;
    return 0.5;
  }

  static String? _firstMatch(List<String> tags, String text) {
    for (final tag in tags) {
      final needle = tag.trim();
      if (needle.isNotEmpty && text.contains(needle.toLowerCase())) {
        return needle;
      }
    }
    return null;
  }

  static double _avoidWeight(InterestProfile profile, String text) {
    var worst = 0.0;
    for (final topic in profile.topics.values) {
      if (topic.score < worst &&
          topic.label.isNotEmpty &&
          text.contains(topic.label.toLowerCase())) {
        worst = topic.score;
      }
    }
    return worst;
  }

  static bool _isExploration(String bvid, int seed) {
    var hash = 17;
    for (final code in bvid.codeUnits) {
      hash = 0x1fffffff & (hash * 31 + code);
    }
    hash ^= seed * 7919;
    return hash % 5 == 0;
  }

  static int _applyExploration(
    List<_ScoredItem> items, {
    required double ratio,
    required int seed,
  }) {
    if (items.length < 4 || ratio <= 0) return 0;
    final slots = math.max(1, (items.length * ratio).round());
    final chosen = <_ScoredItem>[];
    final remaining = <_ScoredItem>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final eligible =
          i >= 2 &&
          !item.features.isFollowed &&
          item.avoidTag == null &&
          (item.model == null || item.score < 0.6);
      if (eligible && chosen.length < slots && (i + seed) % 3 != 0) {
        chosen.add(item);
      } else {
        remaining.add(item);
      }
    }
    if (chosen.isEmpty) return 0;
    var insertAt = 2;
    for (final item in chosen) {
      if (insertAt >= remaining.length) break;
      remaining.insert(insertAt, item);
      insertAt += math.max(2, (remaining.length / (chosen.length + 1)).floor());
    }
    items
      ..clear()
      ..addAll(remaining);
    return chosen.length;
  }

  static void _diversify(List<_ScoredItem> items) {
    for (var i = 1; i < items.length - 1; i++) {
      final prev = items[i - 1].features.ownerMid;
      if (prev == null || items[i].features.ownerMid != prev) continue;
      for (var j = i + 1; j < items.length; j++) {
        if (items[j].features.ownerMid != prev) {
          final tmp = items[i];
          items[i] = items[j];
          items[j] = tmp;
          break;
        }
      }
    }
  }

  static String _reasonFor(
    _ScoredItem item,
    AiRecommendSettings settings,
    InterestProfile? profile,
    Map<String, String> labels,
    bool usedModel,
  ) {
    if (item.wantTag != null) {
      return '匹配你想看的「' + item.wantTag! + '」· 依据标题';
    }
    if (item.model != null && item.model!.matchedInterestIds.isNotEmpty) {
      final first = item.model!.matchedInterestIds.first;
      final label = labels[first];
      if (label != null && label.isNotEmpty) {
        return '与兴趣「' + label + '」相关 · 依据标题/简介';
      }
      return '与你的兴趣设置相关 · 依据标题/简介';
    }
    if (item.model != null && item.model!.topics.isNotEmpty) {
      return '标题/简介涉及「' + item.model!.topics.first + '」· 依据已有标题信息';
    }
    if (item.localMatch > 0.08 && profile != null) {
      final topic = _bestTopic(profile, item.features.matchText);
      if (topic != null) {
        return '与近期常看的「' + topic.label + '」相关 · 依据标题';
      }
    }
    if (item.exploratory) return '为你保留的新主题 · 依据 B 站原排序';
    if (usedModel && item.model != null) {
      return 'AI 判断与你当前兴趣相关 · 依据标题/简介';
    }
    return '保留 B 站原排序';
  }

  static TopicPreference? _bestTopic(InterestProfile profile, String text) {
    TopicPreference? best;
    for (final topic in profile.topics.values) {
      if (topic.score <= 0 ||
          topic.label.isEmpty ||
          !text.contains(topic.label.toLowerCase())) {
        continue;
      }
      if (best == null || topic.score > best.score) best = topic;
    }
    return best;
  }
}

class _ScoredItem {
  _ScoredItem({
    required this.features,
    required this.score,
    required this.model,
    required this.wantTag,
    required this.avoidTag,
    required this.localMatch,
    required this.avoidWeight,
    required this.exploratory,
    required this.fold,
  });

  final VideoFeatures features;
  final double score;
  final AiCandidateScore? model;
  final String? wantTag;
  final String? avoidTag;
  final double localMatch;
  final double avoidWeight;
  final bool exploratory;
  final bool fold;
}
