// ignore_for_file: cascade_invocations
// ignore_for_file: prefer_interpolation_to_compose_strings
import 'dart:math' as math;

import 'package:PiliPlus/models/ai_recommend/ai_recommend_settings.dart';
import 'package:PiliPlus/models/ai_recommend/interest_profile.dart';
import 'package:PiliPlus/models/ai_recommend/video_features.dart';

/// Applies explicit feedback and watch signals to a local interest profile.
///
/// Pure by design: no Hive, no network, no clock unless passed in. The caller
/// decides whether learning is allowed at all (master switch, pause, anonymous
/// account, history account). This class only enforces the numeric rules and
/// the retention bounds.
abstract final class InterestProfileService {
  static const int maxLearningEvents = 1000;
  static const int maxFeedbacks = 100;
  static const int maxTopics = 200;

  /// First version parameters, centralised so later tuning is one edit.
  static const double feedbackMoreTopicDelta = 0.35;
  static const double feedbackLessTopicDelta = 0.45;
  static const double feedbackMoreAuthorDelta = 0.20;
  static const double feedbackLessAuthorDelta = 0.30;

  static InterestProfile applyFeedback(
    InterestProfile profile,
    VideoFeatures features,
    FeedbackKind kind,
    AiRecommendSettings settings, {
    List<String> modelTopics = const [],
    DateTime? now,
  }) {
    final clock = now ?? DateTime.now();
    final base = profile.decayed(clock);
    final labels = _labelsFor(base, features, settings, modelTopics);
    final sign = kind == FeedbackKind.more ? 1.0 : -1.0;
    final topicDelta =
        sign *
        (kind == FeedbackKind.more
            ? feedbackMoreTopicDelta
            : feedbackLessTopicDelta);
    final authorDelta =
        sign *
        (kind == FeedbackKind.more
            ? feedbackMoreAuthorDelta
            : feedbackLessAuthorDelta);

    final topics = Map<String, TopicPreference>.from(base.topics);
    final deltas = <String, double>{};
    for (final entry in labels.entries) {
      final id = entry.key;
      final label = entry.value;
      final old = topics[id];
      final delta = topicDelta * (old == null ? 1.0 : 0.8);
      final recent = ((old?.recent ?? 0) + delta).clamp(-1.0, 1.0);
      final long = ((old?.long ?? 0) + delta * 0.7).clamp(-1.0, 1.0);
      topics[id] = TopicPreference(
        id: id,
        label: label,
        recent: recent,
        long: long,
        confidence: math.max(old?.confidence ?? 0.0, 0.7),
        hits: (old?.hits ?? 0) + 1,
        updatedAtMs: clock.millisecondsSinceEpoch,
        source: 'feedback',
      );
      deltas[id] = recent - (old?.recent ?? 0);
    }

    final authors = Map<int, double>.from(base.authors);
    final mid = features.ownerMid;
    if (mid != null && mid > 0) {
      authors[mid] = ((authors[mid] ?? 0) + authorDelta).clamp(-1.0, 1.0);
    }

    final record = FeedbackRecord(
      id: _eventId(features.bvid, kind.name, clock),
      bvid: features.bvid,
      title: features.title,
      kind: kind,
      atMs: clock.millisecondsSinceEpoch,
      ownerMid: mid,
      topicDeltas: deltas,
      authorDelta: mid != null && mid > 0 ? authorDelta : 0,
    );
    final feedbacks = [...base.feedbacks, record];
    if (feedbacks.length > maxFeedbacks) {
      feedbacks.removeRange(0, feedbacks.length - maxFeedbacks);
    }
    final events = [
      ...base.events,
      LearningEvent(
        bvid: features.bvid,
        atMs: clock.millisecondsSinceEpoch,
        effectiveMs: 0,
        kind: 'feedback:' + kind.name,
      ),
    ];

    return _finish(
      base.copyWith(
        topics: topics,
        authors: authors,
        feedbacks: feedbacks,
        events: events,
        updatedAtMs: clock.millisecondsSinceEpoch,
      ),
      settings,
      clock,
    );
  }

  /// Removes the newest applied feedback and subtracts exactly what it added.
  static InterestProfile undoLastFeedback(
    InterestProfile profile,
    AiRecommendSettings settings, {
    DateTime? now,
  }) {
    if (profile.feedbacks.isEmpty) return profile;
    final clock = now ?? DateTime.now();
    final base = profile.decayed(clock);
    final record = base.feedbacks.last;
    final topics = Map<String, TopicPreference>.from(base.topics);
    record.topicDeltas.forEach((id, delta) {
      final old = topics[id];
      if (old == null) return;
      final recent = (old.recent - delta).clamp(-1.0, 1.0);
      final long = (old.long - delta * 0.7).clamp(-1.0, 1.0);
      if (recent.abs() < 0.01 && long.abs() < 0.01) {
        topics.remove(id);
      } else {
        topics[id] = old.copyWith(
          recent: recent,
          long: long,
          updatedAtMs: clock.millisecondsSinceEpoch,
        );
      }
    });
    final authors = Map<int, double>.from(base.authors);
    final mid = record.ownerMid;
    if (mid != null && mid > 0) {
      final next = (authors[mid] ?? 0) - record.authorDelta;
      if (next.abs() < 0.01) {
        authors.remove(mid);
      } else {
        authors[mid] = next.clamp(-1.0, 1.0);
      }
    }
    return base.copyWith(
      topics: topics,
      authors: authors,
      feedbacks: base.feedbacks.sublist(0, base.feedbacks.length - 1),
      updatedAtMs: clock.millisecondsSinceEpoch,
    );
  }

  /// Applies one already-reduced watch signal. The caller has checked that
  /// learning is allowed for this account and mode.
  static InterestProfile applyWatch(
    InterestProfile profile,
    WatchSignal signal,
    AiRecommendSettings settings, {
    List<String> modelTopics = const [],
    DateTime? now,
  }) {
    if (!signal.isEligible) return profile;
    final clock = now ?? DateTime.now();
    final recentSame = profile.events.any(
      (e) =>
          e.bvid == signal.bvid &&
          clock.millisecondsSinceEpoch - e.atMs <
              const Duration(hours: 6).inMilliseconds,
    );
    if (recentSame) return profile;
    final base = profile.decayed(clock);
    final haystack = signal.title.toLowerCase();
    final blocked = settings.avoidTags.any(
      (tag) => tag.isNotEmpty && haystack.contains(tag.toLowerCase()),
    );
    if (blocked) return base;

    final delta = signal.coverage >= 0.8
        ? 0.25
        : signal.coverage >= 0.4
        ? 0.15
        : 0.07;
    final labels = <String, String>{};
    for (final tag in settings.wantTags) {
      if (tag.isNotEmpty && haystack.contains(tag.toLowerCase())) {
        labels[InterestProfile.topicId(tag)] = tag;
      }
    }
    for (final topic in base.topics.values) {
      if (topic.score > 0.05 &&
          topic.label.isNotEmpty &&
          haystack.contains(topic.label.toLowerCase())) {
        labels[topic.id] = topic.label;
      }
    }
    for (final topic in modelTopics) {
      final clean = topic.trim();
      if (clean.isEmpty) continue;
      labels[InterestProfile.topicId(clean)] = clean;
      if (labels.length >= 4) break;
    }

    final topics = Map<String, TopicPreference>.from(base.topics);
    for (final entry in labels.entries) {
      final old = topics[entry.key];
      topics[entry.key] = TopicPreference(
        id: entry.key,
        label: entry.value,
        recent: ((old?.recent ?? 0) + delta).clamp(-1.0, 1.0),
        long: ((old?.long ?? 0) + delta * 0.5).clamp(-1.0, 1.0),
        confidence: math.max(old?.confidence ?? 0.0, 0.5),
        hits: (old?.hits ?? 0) + 1,
        updatedAtMs: clock.millisecondsSinceEpoch,
        source: 'watch',
      );
    }

    final authors = Map<int, double>.from(base.authors);
    final mid = signal.ownerMid;
    if (mid != null && mid > 0) {
      authors[mid] =
          ((authors[mid] ?? 0) + (signal.coverage >= 0.8 ? 0.12 : 0.06)).clamp(
            -1.0,
            1.0,
          );
    }

    var preferred = base.preferredDurationSeconds;
    if (signal.durationMs >= 60000 && signal.durationMs <= 7200000) {
      final seconds = signal.durationMs ~/ 1000;
      preferred = preferred == 0
          ? seconds
          : (preferred * 0.8 + seconds * 0.2).round();
    }

    return _finish(
      base.copyWith(
        topics: topics,
        authors: authors,
        preferredDurationSeconds: preferred,
        events: [
          ...base.events,
          LearningEvent(
            bvid: signal.bvid,
            atMs: clock.millisecondsSinceEpoch,
            effectiveMs: signal.effectiveMs,
            kind: 'watch',
            backend: signal.backend,
          ),
        ],
        updatedAtMs: clock.millisecondsSinceEpoch,
      ),
      settings,
      clock,
    );
  }

  static InterestProfile removeTopic(
    InterestProfile profile,
    String topicId,
  ) => profile.copyWith(
    topics: Map<String, TopicPreference>.from(profile.topics)..remove(topicId),
  );

  static InterestProfile prune(
    InterestProfile profile,
    AiRecommendSettings settings,
    DateTime now,
  ) {
    final cutoff = now
        .subtract(Duration(days: settings.profileRetentionDays))
        .millisecondsSinceEpoch;
    final events = profile.events.where((e) => e.atMs >= cutoff).toList();
    if (events.length > maxLearningEvents) {
      events.removeRange(0, events.length - maxLearningEvents);
    }
    var topics = Map<String, TopicPreference>.from(profile.topics);
    topics.removeWhere(
      (id, topic) =>
          topic.magnitude < 0.01 &&
          topic.updatedAtMs > 0 &&
          topic.updatedAtMs < cutoff,
    );
    if (topics.length > maxTopics) {
      final sorted = topics.entries.toList()
        ..sort((a, b) => a.value.magnitude.compareTo(b.value.magnitude));
      for (final entry in sorted.take(topics.length - maxTopics)) {
        topics.remove(entry.key);
      }
    }
    return profile.copyWith(
      events: events,
      topics: topics,
      lastDecayMs: profile.lastDecayMs,
    );
  }

  static InterestProfile _finish(
    InterestProfile profile,
    AiRecommendSettings settings,
    DateTime now,
  ) => prune(profile.decayed(now), settings, now);

  static Map<String, String> _labelsFor(
    InterestProfile profile,
    VideoFeatures features,
    AiRecommendSettings settings,
    List<String> modelTopics,
  ) {
    final haystack = features.matchText;
    final labels = <String, String>{};
    for (final tag in [...settings.wantTags, ...settings.avoidTags]) {
      if (tag.isNotEmpty && haystack.contains(tag.toLowerCase())) {
        labels[InterestProfile.topicId(tag)] = tag;
      }
    }
    for (final topic in profile.topics.values) {
      if (topic.label.isNotEmpty &&
          haystack.contains(topic.label.toLowerCase())) {
        labels[topic.id] = topic.label;
      }
    }
    for (final topic in modelTopics) {
      final clean = topic.trim();
      if (clean.isEmpty || clean.length > 40) continue;
      labels[InterestProfile.topicId(clean)] = clean;
      if (labels.length >= 6) break;
    }
    return labels;
  }

  static String _eventId(String bvid, String kind, DateTime at) =>
      bvid + '-' + kind + '-' + at.millisecondsSinceEpoch.toString();
}
