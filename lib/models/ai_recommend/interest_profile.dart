// ignore_for_file: prefer_interpolation_to_compose_strings
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

/// A learned or explicitly seeded topic. Explicit user tags are *not* stored
/// here - they live in settings and are never rewritten by learning. This
/// object only holds inferred preferences.
class TopicPreference {
  const TopicPreference({
    required this.id,
    required this.label,
    required this.recent,
    required this.long,
    required this.confidence,
    required this.hits,
    required this.updatedAtMs,
    this.source = 'watch',
  });

  final String id;
  final String label;

  /// Fast-moving signal with a 7-day half life.
  final double recent;

  /// Slow-moving signal with a 30-day half life.
  final double long;
  final double confidence;
  final int hits;
  final int updatedAtMs;
  final String source;

  double get score => (recent * 0.65 + long * 0.35).clamp(-1.0, 1.0);
  double get magnitude => score.abs();

  TopicPreference decayed(
    DateTime now, {
    double recentHalfLifeDays = 7,
    double longHalfLifeDays = 30,
  }) {
    final days = (now.millisecondsSinceEpoch - updatedAtMs) / 86400000.0;
    if (days <= 0) return this;
    return copyWith(
      recent: _decay(recent, days, recentHalfLifeDays),
      long: _decay(long, days, longHalfLifeDays),
      confidence: _decay(confidence, days, longHalfLifeDays),
      updatedAtMs: now.millisecondsSinceEpoch,
    );
  }

  static double _decay(double value, double days, double halfLife) =>
      value * math.pow(0.5, days / halfLife).toDouble();

  TopicPreference copyWith({
    double? recent,
    double? long,
    double? confidence,
    int? hits,
    int? updatedAtMs,
    String? source,
  }) => TopicPreference(
    id: id,
    label: label,
    recent: recent ?? this.recent,
    long: long ?? this.long,
    confidence: confidence ?? this.confidence,
    hits: hits ?? this.hits,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    source: source ?? this.source,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'recent': _round(recent),
    'long': _round(long),
    'confidence': _round(confidence),
    'hits': hits,
    'updatedAt': updatedAtMs,
    'source': source,
  };

  static TopicPreference? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final label = raw['label'];
    final id = raw['id'];
    if (label is! String || id is! String) return null;
    return TopicPreference(
      id: id,
      label: label.length > 40 ? label.substring(0, 40) : label,
      recent: _clamp(raw['recent']),
      long: _clamp(raw['long']),
      confidence: _unit(raw['confidence']),
      hits: raw['hits'] is int ? (raw['hits'] as int).clamp(0, 100000) : 0,
      updatedAtMs: raw['updatedAt'] is int ? raw['updatedAt'] as int : 0,
      source: raw['source'] is String ? raw['source'] as String : 'watch',
    );
  }

  static double _clamp(Object? value) =>
      value is num ? value.toDouble().clamp(-1.0, 1.0) : 0.0;

  static double _unit(Object? value) =>
      value is num ? value.toDouble().clamp(0.0, 1.0) : 0.5;

  static double _round(double v) => (v * 1000).round() / 1000;
}

enum FeedbackKind {
  more,
  less;

  static FeedbackKind? fromStored(Object? value) {
    for (final kind in values) {
      if (kind.name == value) return kind;
    }
    return null;
  }
}

/// One explicit more/less action. Deltas are stored so undo can subtract the
/// exact contribution instead of guessing.
class FeedbackRecord {
  const FeedbackRecord({
    required this.id,
    required this.bvid,
    required this.title,
    required this.kind,
    required this.atMs,
    this.ownerMid,
    this.topicDeltas = const {},
    this.authorDelta = 0,
  });

  final String id;
  final String bvid;
  final String title;
  final FeedbackKind kind;
  final int atMs;
  final int? ownerMid;
  final Map<String, double> topicDeltas;
  final double authorDelta;

  Map<String, dynamic> toJson() => {
    'id': id,
    'bvid': bvid,
    'title': title.length > 120 ? title.substring(0, 120) : title,
    'kind': kind.name,
    'at': atMs,
    if (ownerMid != null) 'ownerMid': ownerMid,
    'topicDeltas': topicDeltas,
    'authorDelta': authorDelta,
  };

  static FeedbackRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = FeedbackKind.fromStored(raw['kind']);
    final bvid = raw['bvid'];
    if (kind == null || bvid is! String) return null;
    final deltas = <String, double>{};
    if (raw['topicDeltas'] is Map) {
      (raw['topicDeltas'] as Map).forEach((key, value) {
        if (key is String && value is num) {
          deltas[key] = value.toDouble().clamp(-1.0, 1.0);
        }
      });
    }
    return FeedbackRecord(
      id: raw['id'] is String ? raw['id'] as String : '',
      bvid: bvid,
      title: raw['title'] is String ? raw['title'] as String : '',
      kind: kind,
      atMs: raw['at'] is int ? raw['at'] as int : 0,
      ownerMid: raw['ownerMid'] is int ? raw['ownerMid'] as int : null,
      topicDeltas: deltas,
      authorDelta: raw['authorDelta'] is num
          ? (raw['authorDelta'] as num).toDouble().clamp(-1.0, 1.0)
          : 0,
    );
  }
}

/// Local preference memory for one account scope.
///
/// It describes content preferences only. Nothing here derives identity,
/// health, politics or any other sensitive personal attribute, and the model
/// is never allowed to write these fields directly.
/// One compact learning record, kept for retention/pruning and the management
/// UI. It never contains a playback position trace or a precise timestamp of
/// the user's day; only the fact that a video contributed to the profile.
class LearningEvent {
  const LearningEvent({
    required this.bvid,
    required this.atMs,
    required this.effectiveMs,
    required this.kind,
    this.backend = 'unknown',
  });

  final String bvid;
  final int atMs;
  final int effectiveMs;
  final String kind;
  final String backend;

  Map<String, dynamic> toJson() => {
    'bvid': bvid,
    'at': atMs,
    'effectiveMs': effectiveMs,
    'kind': kind,
    'backend': backend,
  };

  static LearningEvent? fromJson(Object? raw) {
    if (raw is! Map || raw['bvid'] is! String) return null;
    return LearningEvent(
      bvid: raw['bvid'] as String,
      atMs: raw['at'] is int ? raw['at'] as int : 0,
      effectiveMs: raw['effectiveMs'] is int ? raw['effectiveMs'] as int : 0,
      kind: raw['kind'] is String ? raw['kind'] as String : 'watch',
      backend: raw['backend'] is String ? raw['backend'] as String : 'unknown',
    );
  }
}

class InterestProfile {
  const InterestProfile({
    required this.accountScope,
    this.topics = const {},
    this.authors = const {},
    this.feedbacks = const [],
    this.events = const [],
    this.lastDecayMs = 0,
    this.updatedAtMs = 0,
    this.preferredDurationSeconds = 0,
    this.schemaVersion = 1,
  });

  static const int currentSchemaVersion = 1;
  static const int maxFeedbacks = 100;
  static const int maxTopics = 200;

  final String accountScope;
  final Map<String, TopicPreference> topics;
  final Map<int, double> authors;
  final List<FeedbackRecord> feedbacks;
  final List<LearningEvent> events;
  final int lastDecayMs;
  final int updatedAtMs;
  final int preferredDurationSeconds;
  final int schemaVersion;

  static InterestProfile empty(String accountScope) =>
      InterestProfile(accountScope: accountScope);

  /// Topic list for the management UI, strongest first, without negligible
  /// weights.
  List<TopicPreference> get visibleTopics {
    final list = topics.values.where((t) => t.magnitude >= 0.05).toList()
      ..sort((a, b) => b.magnitude.compareTo(a.magnitude));
    return list.take(30).toList();
  }

  InterestProfile decayed(DateTime now) {
    if (lastDecayMs > 0 &&
        now.millisecondsSinceEpoch - lastDecayMs <
            const Duration(hours: 1).inMilliseconds) {
      return this;
    }
    final decayedTopics = <String, TopicPreference>{};
    topics.forEach((id, topic) {
      final next = topic.decayed(now);
      if (next.magnitude >= 0.01 || next.hits > 0) {
        decayedTopics[id] = next;
      }
    });
    final decayedAuthors = <int, double>{};
    authors.forEach((mid, weight) {
      final next = weight * math.pow(0.5, _days(now) / 30).toDouble();
      if (next.abs() >= 0.01) decayedAuthors[mid] = next.clamp(-1.0, 1.0);
    });
    return copyWith(
      topics: decayedTopics,
      authors: decayedAuthors,
      lastDecayMs: now.millisecondsSinceEpoch,
    );
  }

  double _days(DateTime now) {
    if (lastDecayMs <= 0) return 0;
    final ms = now.millisecondsSinceEpoch - lastDecayMs;
    return ms <= 0 ? 0 : ms / 86400000.0;
  }

  /// Strongest local match for [text], in [-1, 1].
  ///
  /// Longer phrases win over shorter ones because "Flutter 状态管理" is more
  /// informative than "Flutter" when both appear.
  double matchText(
    String text, {
    List<String> extraPositive = const [],
    List<String> extraNegative = const [],
  }) {
    final haystack = text.toLowerCase();
    var best = 0.0;
    var bestLength = 0;
    topics.forEach((id, topic) {
      final needle = topic.label.toLowerCase();
      if (needle.isEmpty || !haystack.contains(needle)) return;
      if (needle.length > bestLength) {
        best = topic.score;
        bestLength = needle.length;
      }
    });
    for (final tag in extraPositive) {
      final needle = tag.toLowerCase();
      if (needle.isNotEmpty && haystack.contains(needle)) {
        best = math.max(best, 0.5);
        bestLength = math.max(bestLength, needle.length);
      }
    }
    for (final tag in extraNegative) {
      final needle = tag.toLowerCase();
      if (needle.isNotEmpty && haystack.contains(needle)) {
        best = math.min(best, -0.5);
      }
    }
    return best.clamp(-1.0, 1.0);
  }

  double authorScore(int? mid) {
    if (mid == null) return 0;
    return (authors[mid] ?? 0).clamp(-1.0, 1.0);
  }

  InterestProfile copyWith({
    Map<String, TopicPreference>? topics,
    Map<int, double>? authors,
    List<FeedbackRecord>? feedbacks,
    List<LearningEvent>? events,
    int? lastDecayMs,
    int? updatedAtMs,
    int? preferredDurationSeconds,
  }) => InterestProfile(
    accountScope: accountScope,
    topics: topics ?? this.topics,
    authors: authors ?? this.authors,
    feedbacks: feedbacks ?? this.feedbacks,
    events: events ?? this.events,
    lastDecayMs: lastDecayMs ?? this.lastDecayMs,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    preferredDurationSeconds:
        preferredDurationSeconds ?? this.preferredDurationSeconds,
  );

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'accountScope': accountScope,
    'topics': topics.map((id, topic) => MapEntry(id, topic.toJson())),
    'authors': authors.map((mid, weight) => MapEntry(mid.toString(), weight)),
    'feedbacks': feedbacks.map((f) => f.toJson()).toList(),
    'events': events.map((e) => e.toJson()).toList(),
    'lastDecay': lastDecayMs,
    'updatedAt': updatedAtMs,
    'preferredDurationSeconds': preferredDurationSeconds,
  };

  String toJsonString() => jsonEncode(toJson());

  static InterestProfile fromJson(Object? raw, {required String accountScope}) {
    if (raw is! Map) return empty(accountScope);
    final topics = <String, TopicPreference>{};
    if (raw['topics'] is Map) {
      (raw['topics'] as Map).forEach((id, value) {
        final topic = TopicPreference.fromJson(value);
        if (id is String && topic != null) topics[id] = topic;
      });
    }
    final authors = <int, double>{};
    if (raw['authors'] is Map) {
      (raw['authors'] as Map).forEach((key, value) {
        final mid = key is int ? key : int.tryParse(key.toString());
        if (mid != null && value is num) {
          authors[mid] = value.toDouble().clamp(-1.0, 1.0);
        }
      });
    }
    final feedbacks = <FeedbackRecord>[];
    if (raw['feedbacks'] is List) {
      for (final item in raw['feedbacks'] as List) {
        final record = FeedbackRecord.fromJson(item);
        if (record != null) feedbacks.add(record);
      }
    }
    final events = <LearningEvent>[];
    if (raw['events'] is List) {
      for (final item in raw['events'] as List) {
        final event = LearningEvent.fromJson(item);
        if (event != null) events.add(event);
      }
    }
    return InterestProfile(
      accountScope: accountScope,
      topics: topics,
      authors: authors,
      feedbacks: feedbacks,
      events: events,
      lastDecayMs: raw['lastDecay'] is int ? raw['lastDecay'] as int : 0,
      updatedAtMs: raw['updatedAt'] is int ? raw['updatedAt'] as int : 0,
      preferredDurationSeconds: raw['preferredDurationSeconds'] is int
          ? (raw['preferredDurationSeconds'] as int).clamp(0, 24 * 3600)
          : 0,
    );
  }

  /// Stable id for a topic label. Ids, not labels, are sent to the model.
  static String topicId(String label) {
    final normalized = label.trim().toLowerCase();
    final digest = sha1.convert(utf8.encode(normalized)).toString();
    return 'interest_' + digest.substring(0, 12);
  }
}

/// One local watch signal, already reduced to effective viewing.
class WatchSignal {
  const WatchSignal({
    required this.bvid,
    required this.title,
    required this.durationMs,
    required this.effectiveMs,
    required this.completed,
    required this.at,
    this.cid,
    this.ownerMid,
    this.backend = 'unknown',
    this.accountScope = 'anon',
  });

  final String bvid;
  final int? cid;
  final String title;
  final int? ownerMid;
  final int durationMs;
  final int effectiveMs;
  final bool completed;
  final DateTime at;
  final String backend;
  final String accountScope;

  double get coverage =>
      durationMs <= 0 ? 0 : (effectiveMs / durationMs).clamp(0.0, 1.0);

  bool get isEligible =>
      bvid.isNotEmpty &&
      effectiveMs >= 30000 &&
      coverage >= 0.15 &&
      (!completed || effectiveMs >= 20000);

  Map<String, dynamic> toJson() => {
    'bvid': bvid,
    if (cid != null) 'cid': cid,
    'title': title,
    'ownerMid': ownerMid,
    'durationMs': durationMs,
    'effectiveMs': effectiveMs,
    'completed': completed,
    'at': at.millisecondsSinceEpoch,
    'backend': backend,
    'accountScope': accountScope,
  };
}
