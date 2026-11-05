import 'package:PiliPlus/models/ai_recommend/ai_recommend_settings.dart';
import 'package:PiliPlus/models/ai_recommend/interest_profile.dart';
import 'package:PiliPlus/models/ai_recommend/video_features.dart';
import 'package:PiliPlus/utils/ai_recommend/interest_profile_service.dart';
import 'package:flutter_test/flutter_test.dart';

const settings = AiRecommendSettings(
  enabled: true,
  useWatchHistory: true,
  wantTags: ['NAS'],
  avoidTags: ['游戏'],
);

VideoFeatures feature(String title, {int? mid = 42}) => VideoFeatures(
  bvid: 'BV1',
  title: title,
  ownerMid: mid,
  ownerName: 'up',
);

void main() {
  final now = DateTime(2026, 11, 5);

  test('more feedback creates a topic and an author preference', () {
    final next = InterestProfileService.applyFeedback(
      InterestProfile.empty('uid:1'),
      feature('NAS 搭建教程'),
      FeedbackKind.more,
      settings,
      now: now,
    );
    final id = InterestProfile.topicId('NAS');
    expect(next.topics[id]!.score, greaterThan(0.2));
    expect(next.authors[42], greaterThan(0));
    expect(next.feedbacks.length, 1);
  });

  test('less feedback is negative and undo removes exactly its effect', () {
    final more = InterestProfileService.applyFeedback(
      InterestProfile.empty('uid:1'),
      feature('NAS 教程'),
      FeedbackKind.less,
      settings,
      now: now,
    );
    final id = InterestProfile.topicId('NAS');
    expect(more.topics[id]!.score, lessThan(0));
    final undone = InterestProfileService.undoLastFeedback(
      more,
      settings,
      now: now,
    );
    expect(undone.topics.containsKey(id), isFalse);
    expect(undone.authors.containsKey(42), isFalse);
    expect(undone.feedbacks, isEmpty);
  });

  test('watch requires an eligible signal', () {
    final short = WatchSignal(
      bvid: 'BV1',
      title: 'NAS 教程',
      durationMs: 100000,
      effectiveMs: 10000,
      completed: false,
      at: now,
      accountScope: 'uid:1',
    );
    final profile = InterestProfile.empty('uid:1');
    expect(
      InterestProfileService.applyWatch(profile, short, settings, now: now),
      same(profile),
    );
  });

  test('eligible watch updates topics and author', () {
    final signal = WatchSignal(
      bvid: 'BV1',
      title: 'NAS 教程',
      ownerMid: 42,
      durationMs: 100000,
      effectiveMs: 80000,
      completed: true,
      at: now,
      accountScope: 'uid:1',
    );
    final next = InterestProfileService.applyWatch(
      InterestProfile.empty('uid:1'),
      signal,
      settings,
      now: now,
    );
    expect(next.topics[InterestProfile.topicId('NAS')]!.score, greaterThan(0));
    expect(next.authors[42], greaterThan(0));
    expect(next.events.single.bvid, 'BV1');
  });

  test('the same video within six hours is counted once', () {
    final signal = WatchSignal(
      bvid: 'BV1',
      title: 'NAS 教程',
      ownerMid: 42,
      durationMs: 100000,
      effectiveMs: 80000,
      completed: true,
      at: now,
      accountScope: 'uid:1',
    );
    final once = InterestProfileService.applyWatch(
      InterestProfile.empty('uid:1'),
      signal,
      settings,
      now: now,
    );
    final twice = InterestProfileService.applyWatch(
      once,
      signal,
      settings,
      now: now.add(const Duration(hours: 1)),
    );
    expect(twice.events.length, 1);
  });

  test('watch whose title matches an avoid tag does not boost it', () {
    final signal = WatchSignal(
      bvid: 'BV9',
      title: '游戏实况',
      durationMs: 100000,
      effectiveMs: 80000,
      completed: true,
      at: now,
      accountScope: 'uid:1',
    );
    final next = InterestProfileService.applyWatch(
      InterestProfile.empty('uid:1'),
      signal,
      settings,
      now: now,
    );
    expect(next.topics, isEmpty);
  });

  test('retention prunes old events and keeps the bound', () {
    final old = LearningEvent(
      bvid: 'OLD',
      atMs: now.subtract(const Duration(days: 200)).millisecondsSinceEpoch,
      effectiveMs: 1000,
      kind: 'watch',
    );
    final profile = InterestProfile.empty('uid:1').copyWith(events: [old]);
    final signal = WatchSignal(
      bvid: 'NEW',
      title: 'NAS 教程',
      durationMs: 100000,
      effectiveMs: 80000,
      completed: true,
      at: now,
      accountScope: 'uid:1',
    );
    final next = InterestProfileService.applyWatch(
      profile,
      signal,
      settings,
      now: now,
    );
    expect(next.events.map((e) => e.bvid), isNot(contains('OLD')));
    expect(next.events.length, lessThanOrEqualTo(1000));
  });

  test('decay reduces a stale topic without deleting explicit data', () {
    final topic = TopicPreference(
      id: 'interest_x',
      label: 'Flutter',
      recent: 0.9,
      long: 0.9,
      confidence: 0.9,
      hits: 2,
      updatedAtMs: now
          .subtract(const Duration(days: 14))
          .millisecondsSinceEpoch,
    );
    final profile = InterestProfile.empty('uid:1')
        .copyWith(topics: {topic.id: topic});
    final next = profile.decayed(now);
    expect(next.topics[topic.id]!.recent, lessThan(0.9));
    expect(next.topics[topic.id]!.long, lessThan(0.9));
  });

  test('profile json round-trips and rejects wrong types safely', () {
    final profile = InterestProfileService.applyFeedback(
      InterestProfile.empty('uid:1'),
      feature('NAS 教程'),
      FeedbackKind.more,
      settings,
      now: now,
    );
    final restored = InterestProfile.fromJson(
      profile.toJson(),
      accountScope: 'uid:1',
    );
    expect(restored.topics.length, profile.topics.length);
    expect(restored.accountScope, 'uid:1');
    final corrupt = InterestProfile.fromJson({
      'topics': 'bad',
    }, accountScope: 'uid:2');
    expect(corrupt.topics, isEmpty);
  });
}
