import 'package:PiliPlus/models/ai_recommend/ai_recommend_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('defaults are off and have no model', () {
    const s = AiRecommendSettings.defaults;
    expect(s.enabled, isFalse);
    expect(s.mode, AiRecommendMode.preference);
    expect(s.hasModel, isFalse);
    expect(s.useWatchHistory, isFalse);
  });

  test('tags accept both lists and separated text and are de-duplicated', () {
    expect(AiRecommendSettings.parseTags('Flutter\nNAS, NAS; AI'), [
      'Flutter',
      'NAS',
      'AI',
    ]);
    expect(AiRecommendSettings.parseTags(['  Flutter ', 'flutter', '']), [
      'Flutter',
    ]);
  });

  test('out-of-range values are clamped instead of trusted', () {
    final s = AiRecommendSettings.fromMap({
      'enabled': true,
      'mode': 'strict',
      'explorationRatio': 9.0,
      'dailyRequestBudget': -4,
      'batchSize': 999,
      'strictThreshold': 0.01,
      'wantTags': 'NAS',
    });
    expect(s.enabled, isTrue);
    expect(s.mode, AiRecommendMode.strict);
    expect(s.explorationRatio, 0.5);
    expect(s.dailyRequestBudget, 0);
    expect(s.batchSize, 40);
    expect(s.strictThreshold, 0.3);
    expect(s.wantTags, ['NAS']);
  });

  test('corrupt values fall back per field', () {
    final s = AiRecommendSettings.fromMap({
      'enabled': 'yes',
      'mode': 'nonsense',
      'wantTags': 7,
    });
    expect(s.enabled, isFalse);
    expect(s.mode, AiRecommendMode.preference);
    expect(s.wantTags, isEmpty);
  });

  test('toMap is the explicit, non-secret subset', () {
    final map = AiRecommendSettings.defaults
        .copyWith(enabled: true, wantTags: ['NAS'])
        .toMap();
    expect(map['enabled'], isTrue);
    expect(map['wantTags'], ['NAS']);
    expect(map.keys, isNot(contains('apiKey')));
    expect(map.keys, isNot(contains('secret')));
  });
}
