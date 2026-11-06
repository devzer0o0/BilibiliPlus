import 'dart:convert';

import 'package:PiliPlus/models/home/rcmd/result.dart';
import 'package:PiliPlus/models/model_rec_video_item.dart';
import 'package:PiliPlus/utils/parse_int.dart';

/// One card of the last AI-ranked home page, frozen for the next cold start.
///
/// It stores display data only. Scores are kept so the restored card can open
/// its "more/less" feedback sheet without waiting for a model request; they
/// are a copy of a derived judgement, not a new profile.
class AiFeedSnapshotItem {
  const AiFeedSnapshotItem({
    required this.card,
    this.reason = '',
    this.folded = false,
    this.explored = false,
    this.relevance = 0,
    this.confidence = 0,
    this.topics = const [],
  });

  final Map<String, dynamic> card;
  final String reason;
  final bool folded;
  final bool explored;
  final double relevance;
  final double confidence;
  final List<String> topics;

  String? get bvid => switch (card['bvid']) {
    final String value when value.isNotEmpty => value,
    _ => null,
  };

  Map<String, dynamic> toJson() => {
    'card': card,
    'reason': reason,
    if (folded) 'folded': true,
    if (explored) 'explored': true,
    'relevance': relevance,
    'confidence': confidence,
    if (topics.isNotEmpty) 'topics': topics,
  };

  static AiFeedSnapshotItem? tryDecode(Map<String, dynamic> json) {
    final rawCard = json['card'];
    if (rawCard is! Map) return null;
    final card = rawCard.cast<String, dynamic>();
    final bvid = card['bvid'];
    if (bvid is! String || bvid.isEmpty) return null;
    return AiFeedSnapshotItem(
      card: card,
      reason: switch (json['reason']) {
        final String value => value,
        _ => '',
      },
      folded: json['folded'] == true,
      explored: json['explored'] == true,
      relevance: _toDouble(json['relevance']),
      confidence: _toDouble(json['confidence']),
      topics: _toTopics(json['topics']),
    );
  }

  static double _toDouble(Object? value) => value is num ? value.toDouble() : 0;

  static List<String> _toTopics(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final topic in raw)
        if (topic is String && topic.isNotEmpty) topic,
    ];
  }
}

/// Persisted first page of the home feed.
///
/// Written after a successful AI refresh, read synchronously during start-up.
/// It is cache, not backup: [schemaVersion] invalidates it, [ttl] bounds how
/// old a restored feed may be, and account/settings fingerprints stop one
/// user's page from appearing for another.
class AiFeedSnapshot {
  const AiFeedSnapshot({
    required this.savedAtMs,
    required this.accountHash,
    required this.settingsHash,
    required this.source,
    required this.status,
    required this.statusDetail,
    required this.items,
    this.folded = const [],
    this.originalCount = 0,
    this.keptCount = 0,
    this.strictDropped = 0,
    this.exploreCount = 0,
    this.freshScores = 0,
    this.cacheHits = 0,
    this.requestsToday = 0,
    this.waitMs = 0,
  });

  static const int schemaVersion = 1;

  /// A week matches the image cache's default stale period. A feed older than
  /// that is allowed to keep showing while the refresh runs, but not forever.
  static const Duration ttl = Duration(days: 7);

  /// Bounds the snapshot so a long scrolled session cannot turn the cache
  /// entry into an unbounded write.
  static const int maxVisibleItems = 40;
  static const int maxFoldedItems = 20;

  final int savedAtMs;

  /// SHA-256 of the account scope and of the AI settings JSON. The raw values
  /// (mid, keywords) are deliberately not stored in the cache.
  final String accountHash;
  final String settingsHash;
  final String source;
  final String status;
  final String statusDetail;
  final List<AiFeedSnapshotItem> items;
  final List<AiFeedSnapshotItem> folded;
  final int originalCount;
  final int keptCount;
  final int strictDropped;
  final int exploreCount;
  final int freshScores;
  final int cacheHits;
  final int requestsToday;
  final int waitMs;

  DateTime get savedAt => DateTime.fromMillisecondsSinceEpoch(savedAtMs);

  bool isUsable({
    required DateTime now,
    required String accountHash,
    required String settingsHash,
    required String source,
  }) {
    if (items.isEmpty) return false;
    if (this.accountHash != accountHash ||
        this.settingsHash != settingsHash ||
        this.source != source) {
      return false;
    }
    final age = now.difference(savedAt);
    if (age.isNegative) return false;
    return age <= ttl;
  }

  /// Rebuilds the cards in saved order. A damaged entry is skipped instead of
  /// hiding the rest of the feed.
  List<BaseRcmdVideoItemModel> decodeCards(
    List<AiFeedSnapshotItem> entries,
  ) {
    final result = <BaseRcmdVideoItemModel>[];
    final seen = <String>{};
    for (final entry in entries) {
      final bvid = entry.bvid;
      if (bvid == null || !seen.add(bvid)) continue;
      try {
        final card = entry.card;
        final BaseRcmdVideoItemModel model = card['kind'] == 'app'
            ? RcmdVideoItemAppModel.fromCacheJson(card)
            : RcmdVideoItemModel.fromCacheJson(card);
        if ((model.bvid ?? '').isEmpty) continue;
        result.add(model);
      } catch (_) {
        // Skip this card only.
      }
    }
    return result;
  }

  String encode() => jsonEncode(toJson());

  Map<String, dynamic> toJson() => {
    'v': schemaVersion,
    'savedAt': savedAtMs,
    'account': accountHash,
    'settings': settingsHash,
    'source': source,
    'status': status,
    'statusDetail': statusDetail,
    'originalCount': originalCount,
    'keptCount': keptCount,
    'strictDropped': strictDropped,
    'exploreCount': exploreCount,
    'freshScores': freshScores,
    'cacheHits': cacheHits,
    'requestsToday': requestsToday,
    'waitMs': waitMs,
    'items': [for (final item in items) item.toJson()],
    if (folded.isNotEmpty) 'folded': [for (final item in folded) item.toJson()],
  };

  /// Parses a snapshot written by this version. Any malformed top-level field
  /// invalidates the snapshot; malformed cards are skipped individually.
  static AiFeedSnapshot? tryDecode(Object? raw) {
    try {
      final Object? decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! Map) return null;
      final json = decoded.cast<String, dynamic>();
      if (safeToInt(json['v']) != schemaVersion) return null;
      final savedAtMs = safeToInt(json['savedAt']);
      final accountHash = json['account'];
      final settingsHash = json['settings'];
      final source = json['source'];
      if (savedAtMs == null ||
          accountHash is! String ||
          settingsHash is! String ||
          source is! String) {
        return null;
      }
      final items = _decodeItems(json['items'], maxVisibleItems);
      if (items.isEmpty) return null;
      return AiFeedSnapshot(
        savedAtMs: savedAtMs,
        accountHash: accountHash,
        settingsHash: settingsHash,
        source: source,
        status: switch (json['status']) {
          final String value => value,
          _ => 'cached',
        },
        statusDetail: switch (json['statusDetail']) {
          final String value => value,
          _ => '',
        },
        items: items,
        folded: _decodeItems(json['folded'], maxFoldedItems),
        originalCount: safeToInt(json['originalCount']) ?? 0,
        keptCount: safeToInt(json['keptCount']) ?? 0,
        strictDropped: safeToInt(json['strictDropped']) ?? 0,
        exploreCount: safeToInt(json['exploreCount']) ?? 0,
        freshScores: safeToInt(json['freshScores']) ?? 0,
        cacheHits: safeToInt(json['cacheHits']) ?? 0,
        requestsToday: safeToInt(json['requestsToday']) ?? 0,
        waitMs: safeToInt(json['waitMs']) ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  static List<AiFeedSnapshotItem> _decodeItems(Object? raw, int cap) {
    if (raw is! List) return const [];
    final result = <AiFeedSnapshotItem>[];
    final seen = <String>{};
    for (final entry in raw) {
      if (result.length >= cap) break;
      if (entry is! Map) continue;
      final item = AiFeedSnapshotItem.tryDecode(
        entry.cast<String, dynamic>(),
      );
      final bvid = item?.bvid;
      if (item == null || bvid == null || !seen.add(bvid)) continue;
      result.add(item);
    }
    return result;
  }
}
