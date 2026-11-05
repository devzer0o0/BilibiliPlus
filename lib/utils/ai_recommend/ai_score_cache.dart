import 'dart:convert';

import 'package:PiliPlus/models/ai_recommend/ai_score.dart';
import 'package:PiliPlus/models/ai_recommend/video_features.dart';
import 'package:crypto/crypto.dart';
import 'package:hive_ce/hive.dart';

/// Cache key inputs. Changing the account, feed source, candidate metadata,
/// profile version, explicit keywords, provider or prompt version must produce
/// a different key, so a stale score cannot be applied to a different context.
abstract final class AiScoreCacheKey {
  static const int promptVersion = 1;
  static const int profileVersion = 1;

  static String build({
    required String accountScope,
    required String source,
    required VideoFeatures features,
    required String settingsFingerprint,
    required String providerFingerprint,
  }) {
    final metadata = [
      features.bvid,
      features.title,
      features.description ?? '',
      features.durationSeconds.toString(),
      features.ownerMid?.toString() ?? '',
      features.pubdate?.toString() ?? '',
      features.category ?? '',
    ].join('\u0001');
    final raw = [
      accountScope,
      source,
      sha256.convert(utf8.encode(metadata)).toString(),
      profileVersion.toString(),
      settingsFingerprint,
      providerFingerprint,
      promptVersion.toString(),
    ].join('|');
    return sha256.convert(utf8.encode(raw)).toString().substring(0, 40);
  }

  /// Only the fields that can change a judgement. Exploration, budget and
  /// display mode are deliberately excluded: changing them must not throw away
  /// valid scores.
  static String settingsFingerprint({
    required List<String> wantTags,
    required List<String> avoidTags,
    required String description,
  }) {
    final canonical = jsonEncode({
      'want': [...wantTags]..sort(),
      'avoid': [...avoidTags]..sort(),
      'description': description.trim(),
    });
    return sha256.convert(utf8.encode(canonical)).toString().substring(0, 16);
  }
}

class AiScoreCacheEntry {
  const AiScoreCacheEntry({
    required this.score,
    required this.cachedAtMs,
  });

  final AiCandidateScore score;
  final int cachedAtMs;

  Map<String, dynamic> toJson() => {
    'score': {
      'candidateId': score.candidateId,
      'bvid': score.bvid,
      'relevance': score.relevance,
      'confidence': score.confidence,
      'matchedInterestIds': score.matchedInterestIds,
      'matchedAvoidIds': score.matchedAvoidIds,
      'topics': score.topics,
    },
    'at': cachedAtMs,
  };

  static AiScoreCacheEntry? fromJson(Object? raw) {
    if (raw is! Map || raw['score'] is! Map) return null;
    final score = raw['score'] as Map;
    final bvid = score['bvid'];
    final relevance = score['relevance'];
    final confidence = score['confidence'];
    if (bvid is! String || relevance is! num || confidence is! num) {
      return null;
    }
    List<String> strings(Object? value) =>
        value is List ? value.whereType<String>().take(8).toList() : const [];
    return AiScoreCacheEntry(
      cachedAtMs: raw['at'] is int ? raw['at'] as int : 0,
      score: AiCandidateScore(
        candidateId: score['candidateId'] is String
            ? score['candidateId'] as String
            : '',
        bvid: bvid,
        relevance: relevance.toDouble().clamp(0.0, 1.0),
        confidence: confidence.toDouble().clamp(0.0, 1.0),
        matchedInterestIds: strings(score['matchedInterestIds']),
        matchedAvoidIds: strings(score['matchedAvoidIds']),
        topics: strings(score['topics']).take(3).toList(),
      ),
    );
  }
}

abstract interface class AiScoreCache {
  Future<AiScoreCacheEntry?> read(String key);
  Future<void> write(String key, AiScoreCacheEntry entry);
  Future<void> clear();
}

class HiveAiScoreCache implements AiScoreCache {
  HiveAiScoreCache(this.box);

  final Box<dynamic> box;

  static const Duration ttl = Duration(hours: 24);
  static const int capacity = 2000;
  static const String prefix = 'score:';

  @override
  Future<AiScoreCacheEntry?> read(String key) async {
    final entry = AiScoreCacheEntry.fromJson(box.get(prefix + key));
    if (entry == null) return null;
    final age = DateTime.now().millisecondsSinceEpoch - entry.cachedAtMs;
    if (age < 0 || age > ttl.inMilliseconds) {
      await box.delete(prefix + key);
      return null;
    }
    return entry;
  }

  @override
  Future<void> write(String key, AiScoreCacheEntry entry) async {
    await box.put(prefix + key, entry.toJson());
    if (box.length > capacity) {
      final entries = <MapEntry<dynamic, int>>[];
      for (final key in box.keys) {
        if (key is! String || !key.startsWith(prefix)) continue;
        final raw = box.get(key);
        final at = raw is Map && raw['at'] is int ? raw['at'] as int : 0;
        entries.add(MapEntry(key, at));
      }
      entries.sort((a, b) => a.value.compareTo(b.value));
      final remove = entries.length - capacity;
      for (var i = 0; i < remove && i < entries.length; i++) {
        await box.delete(entries[i].key);
      }
    }
  }

  @override
  Future<void> clear() async {
    final keys = box.keys
        .whereType<String>()
        .where((k) => k.startsWith(prefix))
        .toList();
    for (final key in keys) {
      await box.delete(key);
    }
  }
}

class MemoryAiScoreCache implements AiScoreCache {
  MemoryAiScoreCache({DateTime? now}) : _now = now ?? DateTime.now();

  final DateTime _now;
  final Map<String, AiScoreCacheEntry> _entries = {};

  @override
  Future<AiScoreCacheEntry?> read(String key) async {
    final entry = _entries[key];
    if (entry == null) return null;
    if (_now.millisecondsSinceEpoch - entry.cachedAtMs >
        HiveAiScoreCache.ttl.inMilliseconds) {
      _entries.remove(key);
      return null;
    }
    return entry;
  }

  @override
  Future<void> write(String key, AiScoreCacheEntry entry) async {
    _entries[key] = entry;
  }

  @override
  Future<void> clear() async {
    _entries.clear();
  }
}
