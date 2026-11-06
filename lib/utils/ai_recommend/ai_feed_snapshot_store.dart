import 'dart:convert';

import 'package:PiliPlus/models/ai_recommend/ai_feed_snapshot.dart';
import 'package:PiliPlus/models/model_rec_video_item.dart';
import 'package:PiliPlus/utils/ai_recommend/recommendation_pipeline.dart';
import 'package:PiliPlus/utils/ai_recommend/recommendation_ranker.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:crypto/crypto.dart';
import 'package:hive_ce/hive.dart';

/// Stable, non-reversible key for the snapshot's account/settings checks.
///
/// The stored value must not carry a mid or the user's preference text, so
/// both are reduced to a fingerprint before they reach Hive.
String aiFeedFingerprint(String value) =>
    sha256.convert(utf8.encode(value)).toString();

/// Builds the snapshot that [AiFeedSnapshotStore] persists.
///
/// Only what is on screen is saved. [visible] is already in display order and
/// is paired with [page] for the reason and score of each card; folded cards
/// are saved too so "折叠 N" still works after a restart.
AiFeedSnapshot? captureFeedSnapshot({
  required List<BaseRcmdVideoItemModel> visible,
  required AiRankedPage page,
  required Map<String, BaseRcmdVideoItemModel> modelsByBvid,
  required String source,
  required String accountHash,
  required String settingsHash,
  required DateTime savedAt,
}) {
  if (visible.isEmpty) return null;
  final rankedByBvid = <String, RankedRecommendation>{
    for (final item in page.items) item.features.bvid: item,
  };
  final items = <AiFeedSnapshotItem>[];
  final seen = <String>{};
  for (final model in visible) {
    if (items.length >= AiFeedSnapshot.maxVisibleItems) break;
    final bvid = model.bvid;
    if (bvid == null || bvid.isEmpty || !seen.add(bvid)) continue;
    final ranked = rankedByBvid[bvid];
    if (ranked == null) continue;
    final score = page.scores[bvid];
    items.add(
      AiFeedSnapshotItem(
        card: model.toCacheJson(),
        reason: ranked.reason,
        explored: ranked.explored,
        relevance: score?.relevance ?? ranked.score,
        confidence: score?.confidence ?? 0,
        topics: score?.topics ?? const [],
      ),
    );
  }
  if (items.isEmpty) return null;

  final folded = <AiFeedSnapshotItem>[];
  for (final ranked in page.folded) {
    if (folded.length >= AiFeedSnapshot.maxFoldedItems) break;
    final bvid = ranked.features.bvid;
    if (!seen.add(bvid)) continue;
    final model = modelsByBvid[bvid];
    if (model == null) continue;
    final score = page.scores[bvid];
    folded.add(
      AiFeedSnapshotItem(
        card: model.toCacheJson(),
        reason: ranked.reason,
        folded: true,
        explored: ranked.explored,
        relevance: score?.relevance ?? ranked.score,
        confidence: score?.confidence ?? 0,
        topics: score?.topics ?? const [],
      ),
    );
  }

  return AiFeedSnapshot(
    savedAtMs: savedAt.millisecondsSinceEpoch,
    accountHash: accountHash,
    settingsHash: settingsHash,
    source: source,
    status: page.status.name,
    statusDetail: page.statusDetail,
    items: items,
    folded: folded,
    originalCount: page.originalCount,
    keptCount: page.keptCount,
    strictDropped: page.strictDropped,
    exploreCount: page.exploreCount,
    freshScores: page.freshScores,
    cacheHits: page.cacheHits,
    requestsToday: page.requestsToday,
    waitMs: page.waitMs,
  );
}

/// Hive-backed cache for the last home feed.
///
/// Reads are synchronous on purpose: the controller restores the page during
/// [onInit] so the first frame has cards instead of a skeleton. Writes are
/// fire-and-forget from the refresh path and can fail without affecting it.
class AiFeedSnapshotStore {
  AiFeedSnapshotStore(this._box);

  final Box<dynamic> _box;

  AiFeedSnapshot? read() {
    try {
      final raw = _box.get(LocalCacheKey.aiFeedSnapshot);
      if (raw == null) return null;
      return AiFeedSnapshot.tryDecode(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> write(AiFeedSnapshot snapshot) async {
    try {
      await _box.put(LocalCacheKey.aiFeedSnapshot, snapshot.encode());
    } catch (_) {
      // Cache writes are best effort.
    }
  }

  Future<void> clear() async {
    try {
      await _box.delete(LocalCacheKey.aiFeedSnapshot);
    } catch (_) {
      // Nothing to clean up.
    }
  }
}
