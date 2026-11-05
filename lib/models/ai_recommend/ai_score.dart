// ignore_for_file: prefer_interpolation_to_compose_strings
import 'dart:convert';

/// One candidate's model judgement, after client-side validation.
class AiCandidateScore {
  const AiCandidateScore({
    required this.candidateId,
    required this.bvid,
    required this.relevance,
    required this.confidence,
    this.matchedInterestIds = const [],
    this.matchedAvoidIds = const [],
    this.topics = const [],
  });

  final String candidateId;
  final String bvid;
  final double relevance;
  final double confidence;
  final List<String> matchedInterestIds;
  final List<String> matchedAvoidIds;
  final List<String> topics;

  /// Confidence is an auxiliary signal, not a calibrated probability. Pull
  /// low-confidence judgements towards neutral instead of treating them as
  /// certain.
  double get effectiveRelevance =>
      (0.5 + (relevance - 0.5) * confidence).clamp(0.0, 1.0);
}

enum AiScoreError {
  emptyBody,
  tooLarge,
  invalidJson,
  wrongSchema,
  wrongType,
  allItemsInvalid,
}

class AiScoreParseException implements Exception {
  const AiScoreParseException(this.error, [this.detail]);

  final AiScoreError error;
  final String? detail;

  @override
  String toString() =>
      'AiScoreParseException(' + error.name + ', ' + (detail ?? '') + ')';
}

class AiScoreParseResult {
  const AiScoreParseResult({
    required this.scoresByBvid,
    required this.invalidItems,
    required this.missingIds,
  });

  final Map<String, AiCandidateScore> scoresByBvid;
  final int invalidItems;
  final List<String> missingIds;
}

/// Strict client-side validation of the model response.
///
/// Policy, stated once here and asserted in tests:
///  * unknown or duplicate candidate ids are dropped (that item only);
///  * unknown interest ids are removed from the match list, not fatal;
///  * a malformed item is dropped and counted; if no item survives, the whole
///    response is rejected so the caller falls back instead of applying empty
///    scores;
///  * missing candidates are reported and treated as unknown - never as
///    "not interested".
abstract final class AiScoreParser {
  static const int schemaVersion = 1;
  static const int maxResponseBytes = 256 * 1024;

  static AiScoreParseResult parse(
    String body, {
    required Map<String, String> requestIdToBvid,
    required Set<String> allowedInterestIds,
    required Set<String> allowedAvoidIds,
  }) {
    if (body.length > maxResponseBytes) {
      throw const AiScoreParseException(AiScoreError.tooLarge);
    }
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      throw const AiScoreParseException(AiScoreError.emptyBody);
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (e) {
      throw AiScoreParseException(AiScoreError.invalidJson, e.toString());
    }
    if (decoded is! Map<String, dynamic>) {
      throw const AiScoreParseException(AiScoreError.wrongType);
    }
    final schema = decoded['schemaVersion'];
    if (schema is! int || schema != schemaVersion) {
      throw AiScoreParseException(
        AiScoreError.wrongSchema,
        'schemaVersion=' + schema.toString(),
      );
    }
    final items = decoded['items'];
    if (items is! List) {
      throw const AiScoreParseException(AiScoreError.wrongType);
    }

    final scores = <String, AiCandidateScore>{};
    var invalid = 0;
    for (final raw in items) {
      if (raw is! Map) {
        invalid++;
        continue;
      }
      final candidateId = raw['candidateId'];
      if (candidateId is! String) {
        invalid++;
        continue;
      }
      final bvid = requestIdToBvid[candidateId];
      if (bvid == null || scores.containsKey(bvid)) {
        // Unknown id, or a duplicate for an already accepted candidate.
        invalid++;
        continue;
      }
      final relevance = _unit(raw['relevance']);
      final confidence = _unit(raw['confidence']);
      if (relevance == null || confidence == null) {
        invalid++;
        continue;
      }
      final topics = _topics(raw['topics']);
      if (topics == null) {
        invalid++;
        continue;
      }
      scores[bvid] = AiCandidateScore(
        candidateId: candidateId,
        bvid: bvid,
        relevance: relevance,
        confidence: confidence,
        matchedInterestIds: _ids(
          raw['matchedInterestIds'],
          allowed: allowedInterestIds,
        ),
        matchedAvoidIds: _ids(raw['matchedAvoidIds'], allowed: allowedAvoidIds),
        topics: topics,
      );
    }

    if (scores.isEmpty && items.isNotEmpty) {
      throw const AiScoreParseException(AiScoreError.allItemsInvalid);
    }

    final missing = requestIdToBvid.values
        .where((bvid) => !scores.containsKey(bvid))
        .toList();
    return AiScoreParseResult(
      scoresByBvid: scores,
      invalidItems: invalid,
      missingIds: missing,
    );
  }

  static double? _unit(Object? value) {
    if (value is! num) return null;
    final v = value.toDouble();
    if (v.isNaN || v.isInfinite || v < 0 || v > 1) return null;
    return v;
  }

  static List<String> _ids(
    Object? value, {
    required Set<String> allowed,
  }) {
    if (value is! List) return const [];
    final result = <String>[];
    for (final id in value) {
      if (id is String && allowed.contains(id) && !result.contains(id)) {
        result.add(id);
      }
      if (result.length >= 8) break;
    }
    return result;
  }

  static List<String>? _topics(Object? value) {
    if (value == null) return const [];
    if (value is! List) return null;
    final result = <String>[];
    for (final topic in value) {
      if (topic is! String) return null;
      final clean = topic.trim();
      if (clean.isEmpty) continue;
      result.add(clean.length > 40 ? clean.substring(0, 40) : clean);
      if (result.length >= 3) break;
    }
    return result;
  }
}
