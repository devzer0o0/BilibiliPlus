import 'dart:convert';

import 'package:PiliPlus/models/ai_recommend/ai_feed_snapshot.dart';
import 'package:PiliPlus/models/ai_recommend/ai_score.dart';
import 'package:PiliPlus/models/ai_recommend/video_features.dart';
import 'package:PiliPlus/models/home/rcmd/result.dart';
import 'package:PiliPlus/models/model_rec_video_item.dart';
import 'package:PiliPlus/utils/ai_recommend/ai_feed_snapshot_store.dart';
import 'package:PiliPlus/utils/ai_recommend/recommendation_pipeline.dart';
import 'package:PiliPlus/utils/ai_recommend/recommendation_ranker.dart';
import 'package:flutter_test/flutter_test.dart';

RcmdVideoItemModel webCard(String bvid, {String? title}) {
  return RcmdVideoItemModel.fromJson({
    'id': 100,
    'bvid': bvid,
    'cid': 200,
    'goto': 'av',
    'uri': 'bilibili://video/$bvid',
    'pic': 'https://i0.hdslb.com/$bvid.jpg',
    'title': title ?? 'web $bvid',
    'duration': 120,
    'pubdate': 1700000000,
    'owner': {'mid': 42, 'name': 'UP'},
    'stat': {'view': 100, 'like': 10, 'danmaku': 2},
    'is_followed': 0,
    'rcmd_reason': {'content': '因为你喜欢'},
  });
}

RcmdVideoItemAppModel appCard(String bvid, {String? title}) {
  return RcmdVideoItemAppModel.fromJson({
    'player_args': {'aid': 100, 'cid': 200, 'duration': 120},
    'bvid': bvid,
    'cover': 'https://i0.hdslb.com/$bvid.jpg',
    'title': title ?? 'app $bvid',
    'card_goto': 'av',
    'rcmd_reason': '',
    'param': '42',
    'uri': 'bilibili://video/$bvid',
    'pubdate': 1700000000,
    'desc': '一个视频',
    'talk_back': '聊一聊',
    'card_type': 'small_cover_v2',
    'cover_left_text_1': '1.2万',
    'cover_left_text_2': '3',
    'args': {'up_name': 'UP', 'up_id': 42},
    'three_point_v2': [
      {
        'type': 'dislike',
        'reasons': [
          {'id': 1, 'name': '不感兴趣', 'toast': '会少一些'},
        ],
      },
      {
        'type': 'feedback',
        'reasons': [
          {'id': 2, 'name': '不推荐', 'toast': '已记录'},
        ],
      },
    ],
  });
}

AiRankedPage rankedPage(
  List<BaseRcmdVideoItemModel> visible, {
  List<BaseRcmdVideoItemModel> folded = const [],
}) {
  final items = <RankedRecommendation>[];
  final scores = <String, AiCandidateScore>{};
  for (var i = 0; i < visible.length; i++) {
    final card = visible[i];
    final bvid = card.bvid!;
    items.add(
      RankedRecommendation(
        features: VideoFeatures.fromRecommendation(
          card,
          index: i,
          source: 'web',
        ),
        score: 0.5 + i * 0.1,
        reason: 'reason $bvid',
      ),
    );
    scores[bvid] = AiCandidateScore(
      candidateId: 'candidate-$i',
      bvid: bvid,
      relevance: 0.8,
      confidence: 0.9,
      topics: const ['NAS'],
    );
  }
  final foldedItems = <RankedRecommendation>[];
  for (var i = 0; i < folded.length; i++) {
    foldedItems.add(
      RankedRecommendation(
        features: VideoFeatures.fromRecommendation(
          folded[i],
          index: visible.length + i,
          source: 'web',
        ),
        score: 0.2,
        reason: 'folded reason',
        folded: true,
      ),
    );
  }
  return AiRankedPage(
    items: items,
    folded: foldedItems,
    status: AiFeedStatus.cached,
    statusDetail: '使用缓存',
    originalCount: visible.length,
    keptCount: visible.length,
    strictDropped: 0,
    exploreCount: 1,
    freshScores: 2,
    cacheHits: 3,
    requestsToday: 4,
    waitMs: 5,
    scores: scores,
  );
}

void main() {
  final savedAt = DateTime.fromMillisecondsSinceEpoch(1700000000000);
  final account = aiFeedFingerprint('account:1');
  final settings = aiFeedFingerprint('settings:1');

  AiFeedSnapshot capture(
    List<BaseRcmdVideoItemModel> visible, {
    List<BaseRcmdVideoItemModel> folded = const [],
  }) {
    final page = rankedPage(visible, folded: folded);
    return captureFeedSnapshot(
      visible: visible,
      page: page,
      modelsByBvid: {
        for (final card in [...visible, ...folded]) card.bvid!: card,
      },
      source: 'web',
      accountHash: account,
      settingsHash: settings,
      savedAt: savedAt,
    )!;
  }

  test('round-trips visible and folded cards with their reasons', () {
    final first = webCard('BV1');
    final second = appCard('BV2');
    final folded = webCard('BV3');
    final restored = AiFeedSnapshot.tryDecode(
      capture([first, second], folded: [folded]).encode(),
    )!;

    expect(restored.items.map((item) => item.bvid), ['BV1', 'BV2']);
    expect(restored.folded.single.bvid, 'BV3');
    expect(restored.items.first.reason, 'reason BV1');
    expect(restored.items.last.topics, ['NAS']);
    expect(restored.originalCount, 2);
    expect(restored.exploreCount, 1);
    expect(restored.freshScores, 2);
    expect(restored.cacheHits, 3);
    expect(restored.requestsToday, 4);
    expect(restored.waitMs, 5);

    final cards = restored.decodeCards(restored.items);
    expect(cards, hasLength(2));
    expect(cards.first, isA<RcmdVideoItemModel>());
    expect(cards.first.title, 'web BV1');
    expect(cards.first.cover, 'https://i0.hdslb.com/BV1.jpg');
    expect(cards.first.stat.view, 100);
    expect(cards.first.owner.name, 'UP');
    final app = cards.last as RcmdVideoItemAppModel;
    expect(app.title, 'app BV2');
    expect(app.owner.mid, 42);
    expect(app.stat.view, 12000);
    expect(app.threePoint?.dislikeReasons?.single.name, '不感兴趣');
    expect(restored.decodeCards(restored.folded).single.bvid, 'BV3');
  });

  test('only restores for the same account, settings and source', () {
    final snapshot = capture([webCard('BV1')]);
    expect(
      snapshot.isUsable(
        now: savedAt.add(const Duration(days: 6)),
        accountHash: account,
        settingsHash: settings,
        source: 'web',
      ),
      isTrue,
    );
    expect(
      snapshot.isUsable(
        now: savedAt,
        accountHash: aiFeedFingerprint('account:2'),
        settingsHash: settings,
        source: 'web',
      ),
      isFalse,
    );
    expect(
      snapshot.isUsable(
        now: savedAt,
        accountHash: account,
        settingsHash: aiFeedFingerprint('settings:2'),
        source: 'web',
      ),
      isFalse,
    );
    expect(
      snapshot.isUsable(
        now: savedAt,
        accountHash: account,
        settingsHash: settings,
        source: 'app',
      ),
      isFalse,
    );
  });

  test('expires after seven days and rejects a future timestamp', () {
    final snapshot = capture([webCard('BV1')]);
    expect(
      snapshot.isUsable(
        now: savedAt.add(const Duration(days: 7)),
        accountHash: account,
        settingsHash: settings,
        source: 'web',
      ),
      isTrue,
    );
    expect(
      snapshot.isUsable(
        now: savedAt.add(const Duration(days: 7, seconds: 1)),
        accountHash: account,
        settingsHash: settings,
        source: 'web',
      ),
      isFalse,
    );
    expect(
      snapshot.isUsable(
        now: savedAt.subtract(const Duration(minutes: 1)),
        accountHash: account,
        settingsHash: settings,
        source: 'web',
      ),
      isFalse,
    );
  });

  test('rejects corrupt JSON, unknown schema and empty pages', () {
    expect(AiFeedSnapshot.tryDecode('not json'), isNull);
    expect(AiFeedSnapshot.tryDecode('{"v":2}'), isNull);
    expect(
      decodeSnapshotWithItems(const []),
      isNull,
    );
  });

  test('skips damaged cards instead of losing the rest', () {
    final restored = AiFeedSnapshot.tryDecode(
      jsonEncode({
        'v': 1,
        'savedAt': savedAt.millisecondsSinceEpoch,
        'account': account,
        'settings': settings,
        'source': 'web',
        'items': [
          {
            'card': {'kind': 'web', 'bvid': 'BV1', 'title': 'still here'},
          },
          {'card': <String, dynamic>{}},
        ],
        'folded': [
          {
            'card': {'kind': 'web', 'bvid': '', 'title': 'gone'},
          },
        ],
      }),
    )!;
    expect(restored.items, hasLength(1));
    expect(restored.decodeCards(restored.items).single.title, 'still here');
    expect(restored.folded, isEmpty);
  });

  test('does not persist a card that is not on the ranked page', () {
    final shown = webCard('BV1');
    final extra = webCard('BV2');
    final page = rankedPage([shown]);
    final snapshot = captureFeedSnapshot(
      visible: [shown, extra],
      page: page,
      modelsByBvid: {'BV1': shown, 'BV2': extra},
      source: 'web',
      accountHash: account,
      settingsHash: settings,
      savedAt: savedAt,
    )!;
    expect(snapshot.items.map((item) => item.bvid), ['BV1']);
  });

  test('caps the persisted page', () {
    final cards = [
      for (var i = 0; i < 45; i++) webCard('BV$i'),
    ];
    final page = rankedPage(cards);
    final snapshot = captureFeedSnapshot(
      visible: cards,
      page: page,
      modelsByBvid: {for (final card in cards) card.bvid!: card},
      source: 'web',
      accountHash: account,
      settingsHash: settings,
      savedAt: savedAt,
    )!;
    expect(snapshot.items, hasLength(AiFeedSnapshot.maxVisibleItems));
  });
}

AiFeedSnapshot? decodeSnapshotWithItems(List<Object?> items) {
  return AiFeedSnapshot.tryDecode(
    jsonEncode({
      'v': 1,
      'savedAt': 1700000000000,
      'account': 'a',
      'settings': 's',
      'source': 'web',
      'items': items,
    }),
  );
}
