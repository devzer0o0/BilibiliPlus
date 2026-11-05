import 'dart:convert';

import 'package:PiliPlus/models/ai_recommend/ai_score.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, String> ids() => {'c1': 'BV1', 'c2': 'BV2'};
  Set<String> interests() => {'interest_1'};
  Set<String> avoids() => {'interest_2'};

  test('parses a valid schema-v1 response', () {
    final body = jsonEncode({
      'schemaVersion': 1,
      'items': [
        {
          'candidateId': 'c1',
          'relevance': 0.86,
          'confidence': 0.8,
          'matchedInterestIds': ['interest_1', 'unknown'],
          'matchedAvoidIds': [],
          'topics': ['Flutter', '状态管理'],
        },
      ],
    });
    final result = AiScoreParser.parse(
      body,
      requestIdToBvid: ids(),
      allowedInterestIds: interests(),
      allowedAvoidIds: avoids(),
    );
    expect(result.scoresByBvid['BV1']!.relevance, 0.86);
    expect(result.scoresByBvid['BV1']!.matchedInterestIds, ['interest_1']);
    expect(result.missingIds, ['BV2']);
  });

  test('missing candidate stays unknown rather than becoming zero', () {
    final body = jsonEncode({
      'schemaVersion': 1,
      'items': [
        {'candidateId': 'c1', 'relevance': 0.2, 'confidence': 1.0},
      ],
    });
    final result = AiScoreParser.parse(
      body,
      requestIdToBvid: ids(),
      allowedInterestIds: interests(),
      allowedAvoidIds: avoids(),
    );
    expect(result.scoresByBvid.containsKey('BV2'), isFalse);
    expect(result.missingIds, ['BV2']);
  });

  test('unknown and duplicate ids are dropped, not applied', () {
    final body = jsonEncode({
      'schemaVersion': 1,
      'items': [
        {'candidateId': 'c9', 'relevance': 0.9, 'confidence': 1.0},
        {'candidateId': 'c1', 'relevance': 0.9, 'confidence': 1.0},
        {'candidateId': 'c1', 'relevance': 0.1, 'confidence': 1.0},
      ],
    });
    final result = AiScoreParser.parse(
      body,
      requestIdToBvid: ids(),
      allowedInterestIds: interests(),
      allowedAvoidIds: avoids(),
    );
    expect(result.scoresByBvid.length, 1);
    expect(result.scoresByBvid['BV1']!.relevance, 0.9);
    expect(result.invalidItems, 2);
  });

  test('out-of-range numbers invalidate only that item', () {
    final body = jsonEncode({
      'schemaVersion': 1,
      'items': [
        {'candidateId': 'c1', 'relevance': 1.7, 'confidence': 1.0},
        {'candidateId': 'c2', 'relevance': 0.4, 'confidence': 0.5},
      ],
    });
    final result = AiScoreParser.parse(
      body,
      requestIdToBvid: ids(),
      allowedInterestIds: interests(),
      allowedAvoidIds: avoids(),
    );
    expect(result.scoresByBvid.length, 1);
    expect(result.scoresByBvid['BV2']!.relevance, 0.4);
    expect(result.invalidItems, 1);
  });

  test('wrong schema, empty, malformed and non-object bodies are rejected', () {
    for (final body in [
      '',
      'not json',
      '[]',
      '{"schemaVersion":2,"items":[]}',
      '{"schemaVersion":1,"items":"x"}',
    ]) {
      expect(
        () => AiScoreParser.parse(
          body,
          requestIdToBvid: ids(),
          allowedInterestIds: interests(),
          allowedAvoidIds: avoids(),
        ),
        throwsA(isA<AiScoreParseException>()),
        reason: body,
      );
    }
  });

  test('all-invalid items reject the response instead of applying none', () {
    final body = jsonEncode({
      'schemaVersion': 1,
      'items': [
        {'candidateId': 'c1', 'relevance': 'high', 'confidence': 1.0},
      ],
    });
    expect(
      () => AiScoreParser.parse(
        body,
        requestIdToBvid: ids(),
        allowedInterestIds: interests(),
        allowedAvoidIds: avoids(),
      ),
      throwsA(isA<AiScoreParseException>()),
    );
  });

  test('oversized body is rejected before parsing', () {
    final body = 'x' * (AiScoreParser.maxResponseBytes + 1);
    expect(
      () => AiScoreParser.parse(
        body,
        requestIdToBvid: ids(),
        allowedInterestIds: interests(),
        allowedAvoidIds: avoids(),
      ),
      throwsA(
        isA<AiScoreParseException>().having(
          (e) => e.error,
          'error',
          AiScoreError.tooLarge,
        ),
      ),
    );
  });

  test('confidence moves low-confidence relevance towards neutral', () {
    const high = AiCandidateScore(
      candidateId: 'c1',
      bvid: 'BV1',
      relevance: 0.9,
      confidence: 1.0,
    );
    const low = AiCandidateScore(
      candidateId: 'c1',
      bvid: 'BV1',
      relevance: 0.9,
      confidence: 0.2,
    );
    expect(high.effectiveRelevance, closeTo(0.9, 1e-9));
    expect(low.effectiveRelevance, lessThan(high.effectiveRelevance));
    expect(low.effectiveRelevance, greaterThan(0.5));
  });
}
