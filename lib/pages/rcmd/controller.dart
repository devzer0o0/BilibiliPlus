import 'dart:async';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/ai_recommend/ai_card_actions.dart';
import 'package:PiliPlus/models/ai_recommend/ai_feed_snapshot.dart';
import 'package:PiliPlus/models/ai_recommend/ai_recommend_settings.dart';
import 'package:PiliPlus/models/ai_recommend/ai_score.dart';
import 'package:PiliPlus/models/ai_recommend/interest_profile.dart';
import 'package:PiliPlus/models/ai_recommend/video_features.dart';
import 'package:PiliPlus/models/common/msg/shared_video.dart';
import 'package:PiliPlus/models/model_rec_video_item.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/pages/setting/ai_recommend.dart';
import 'package:PiliPlus/utils/ai_recommend/ai_feed_snapshot_store.dart';
import 'package:PiliPlus/utils/ai_recommend/ai_recommendation_service.dart';
import 'package:PiliPlus/utils/ai_recommend/recommendation_pipeline.dart';
import 'package:PiliPlus/utils/ai_recommend/recommendation_ranker.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/home_feed_policy.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/shared_video_read_store.dart';
import 'package:PiliPlus/utils/shared_video_service.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class _PreparedAiPage {
  const _PreparedAiPage({
    required this.cursor,
    required this.models,
    required this.page,
    required this.signature,
    required this.accountScope,
    required this.source,
  });

  final int cursor;
  final List<BaseRcmdVideoItemModel> models;
  final AiRankedPage page;
  final String signature;
  final String accountScope;
  final String source;
}

class RcmdController extends CommonListController {
  late bool enableSaveLastData = Pref.enableSaveLastData;
  final bool appRcmd = Pref.appRcmd;

  int? lastRefreshAt;
  late bool savedRcmdTip = Pref.savedRcmdTip;

  final AiRecommendationService _ai = AiRecommendationService.instance;
  final RecommendationSession _aiSession = RecommendationSession();
  final Rxn<AiRankedPage> aiPage = Rxn<AiRankedPage>();
  final RxBool aiNewRankingReady = false.obs;
  final RxInt aiRestoredFolded = 0.obs;

  /// Why the background AI pass could not improve the page (daily budget used
  /// up, missing key, model error). Empty when there is nothing to report.
  /// Without it the bar keeps saying "local rules" and the user cannot tell a
  /// slow hand-off from a request that never left the device.
  final RxString aiBlockedReason = ''.obs;

  RecommendationToken? _aiToken;
  int _aiTopUpUsed = 0;
  final Map<String, int> _lastShownAtMs = {};
  final Map<String, VideoFeatures> _featuresByBvid = {};
  final Set<String> _seenBvids = {};
  final Map<String, BaseRcmdVideoItemModel> _modelsByBvid = {};
  final List<BaseRcmdVideoItemModel> _allCandidates = [];
  _PreparedAiPage? _preparedAi;
  bool _preparingAi = false;
  bool _prefetchQueued = false;
  // How many cards the last paint put on screen. A background re-rank may
  // replace the list in place only while this still matches, so a feed the
  // user has already scrolled or refreshed is never reshuffled under them.
  int _aiPaintedLength = 0;
  int _prefetchEpoch = 0;
  AiFeedSnapshotStore? _feedSnapshotStore;
  bool _feedRestored = false;
  // The grid asks for "more" while it lays out the last cached tile, which at
  // launch would turn into an immediate network request. Keep the restored page
  // untouched until the user actually scrolls.
  bool _restoredLoadMoreGate = false;
  final Set<String> _warmedCoverUrls = {};

  bool get aiEnabled {
    try {
      return _ai.settings.enabled;
    } catch (_) {
      return false;
    }
  }

  AiRecommendSettings get aiSettings => _ai.settings;

  AiCardActions? aiCardActionsFor(String bvid) {
    final pageData = aiPage.value;
    if (pageData == null) return null;
    for (final item in pageData.items) {
      if (item.features.bvid == bvid) {
        return AiCardActions(
          reason: item.reason,
          onMore: () => aiFeedback(bvid, FeedbackKind.more),
          onLess: () => aiFeedback(bvid, FeedbackKind.less),
          onUndo: aiUndo,
        );
      }
    }
    return null;
  }

  int get aiFoldedCount {
    final total = aiPage.value?.foldedCount ?? 0;
    final restored = aiRestoredFolded.value;
    return total > restored ? total - restored : 0;
  }

  /// Videos shared over private messages, newest first, minus what was opened.
  /// Shown above the grid and deliberately not part of AI candidate selection.
  final RxList<SharedVideo> sharedVideos = <SharedVideo>[].obs;

  AiFeedSnapshotStore? get _snapshotStore {
    final existing = _feedSnapshotStore;
    if (existing != null) return existing;
    try {
      return _feedSnapshotStore = AiFeedSnapshotStore(GStorage.localCache);
    } catch (_) {
      return null;
    }
  }

  /// Paints the previous session's AI page before any network request.
  ///
  /// Hive is already open when this controller is created, so the restore is
  /// synchronous and the first frame has cards. Returns true when a usable
  /// page was painted: the caller then skips the start-up refresh, because
  /// the feed on screen is already the page the user saw last time. A pull to
  /// refresh still replaces it, and [handleError] keeps the cached cards if
  /// such a refresh fails instead of falling back to a skeleton.
  bool _restoreFeedSnapshot() {
    final source = appRcmd ? 'app' : 'web';
    final accountHash = aiFeedFingerprint(_ai.recommendScope);
    final settingsHash = aiFeedFingerprint(_ai.settings.toJson());
    if (!aiEnabled) return false;
    final store = _snapshotStore;
    if (store == null) return false;
    final snapshot = store.read();
    if (snapshot == null) return false;
    if (!snapshot.isUsable(
      now: DateTime.now(),
      accountHash: accountHash,
      settingsHash: settingsHash,
      source: source,
    )) {
      return false;
    }
    final visibleCards = snapshot.decodeCards(snapshot.items);
    if (visibleCards.isEmpty) {
      return false;
    }
    final foldedCards = snapshot.decodeCards(snapshot.folded);
    final cardsByBvid = <String, BaseRcmdVideoItemModel>{
      for (final card in visibleCards) card.bvid!: card,
      for (final card in foldedCards) card.bvid!: card,
    };

    final items = <RankedRecommendation>[];
    final display = <BaseRcmdVideoItemModel>[];
    final scores = <String, AiCandidateScore>{};
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final entry in snapshot.items) {
      final bvid = entry.bvid;
      final card = bvid == null ? null : cardsByBvid[bvid];
      if (bvid == null || card == null || !_seenBvids.add(bvid)) continue;
      final item = RankedRecommendation(
        features: VideoFeatures.fromRecommendation(
          card,
          index: items.length,
          source: source,
        ),
        score: entry.relevance,
        reason: entry.reason,
        explored: entry.explored,
      );
      items.add(item);
      display.add(card);
      _modelsByBvid[bvid] = card;
      _featuresByBvid[bvid] = item.features;
      _lastShownAtMs[bvid] = now;
      _rememberSnapshotScore(scores, entry);
    }
    if (items.isEmpty) return false;

    final folded = <RankedRecommendation>[];
    for (final entry in snapshot.folded) {
      final bvid = entry.bvid;
      final card = bvid == null ? null : cardsByBvid[bvid];
      if (bvid == null || card == null || !_seenBvids.add(bvid)) continue;
      final item = RankedRecommendation(
        features: VideoFeatures.fromRecommendation(
          card,
          index: items.length + folded.length,
          source: source,
        ),
        score: entry.relevance,
        reason: entry.reason,
        folded: true,
        explored: entry.explored,
      );
      folded.add(item);
      _modelsByBvid[bvid] = card;
      _featuresByBvid[bvid] = item.features;
      _lastShownAtMs[bvid] = now;
      _rememberSnapshotScore(scores, entry);
    }

    aiPage.value = AiRankedPage(
      items: items,
      folded: folded,
      status: AiFeedStatus.cached,
      statusDetail: '已恢复上次的 AI 推荐 · 下拉刷新',
      originalCount: snapshot.originalCount,
      keptCount: snapshot.keptCount,
      strictDropped: snapshot.strictDropped,
      exploreCount: snapshot.exploreCount,
      freshScores: 0,
      cacheHits: snapshot.cacheHits,
      requestsToday: snapshot.requestsToday,
      waitMs: 0,
      scores: scores,
    );
    _feedRestored = true;
    _restoredLoadMoreGate = true;
    // Restored cards are already one page; without this the first onLoadMore
    // would see page == 0 and trigger a full refresh.
    page = 1;
    isEnd = false;
    _aiPaintedLength = display.length;
    loadingState.value = Success<List<BaseRcmdVideoItemModel>>(display);
    return true;
  }

  void _rememberSnapshotScore(
    Map<String, AiCandidateScore> scores,
    AiFeedSnapshotItem entry,
  ) {
    final bvid = entry.bvid;
    if (bvid == null) return;
    if (entry.relevance <= 0 && entry.confidence <= 0 && entry.topics.isEmpty) {
      return;
    }
    scores[bvid] = AiCandidateScore(
      candidateId: 'snapshot:$bvid',
      bvid: bvid,
      relevance: entry.relevance,
      confidence: entry.confidence,
      topics: entry.topics,
    );
  }

  @override
  void onInit() {
    super.onInit();
    page = 0;
    // Cached cards are the whole point of the snapshot: when there is a usable
    // page, launching costs no recommendation request at all. A refresh runs
    // only when nothing could be restored, or when the user pulls to refresh.
    final restored = _restoreFeedSnapshot();
    if (restored) {
      // Keep the AI session alive without a request so scrolling continues
      // through the pipeline instead of appending unscored upstream cards.
      _aiToken = _aiSession.begin();
    } else {
      unawaited(queryData());
    }
    loadSharedVideos();
  }

  @override
  Future<void> onLoadMore() {
    if (_restoredLoadMoreGate) {
      final atTop =
          !scrollController.hasClients || scrollController.position.pixels <= 0;
      if (atTop) return Future.value();
      _restoredLoadMoreGate = false;
    }
    return super.onLoadMore();
  }

  Future<void> loadSharedVideos() async {
    try {
      final loaded = await SharedVideoService.load();
      sharedVideos.value = HomeFeedPolicy.sharedSection(
        loaded,
        SharedVideoReadStore.opened,
      );
    } catch (_) {
      sharedVideos.value = const [];
    }
  }

  Future<void> onSharedVideoOpened(String bvid) async {
    await SharedVideoReadStore.markOpened(bvid);
    sharedVideos.removeWhere((v) => v.bvid == bvid);
  }

  Future<void> topUpGrid() async {
    var extra = 0;
    var current = _currentLength;
    while (HomeFeedPolicy.needsMore(
      currentLength: current,
      fetchedPages: extra,
      atEnd: isEnd,
    )) {
      if (aiEnabled && _aiTopUpUsed >= HomeFeedPolicy.maxTopUpPages) break;
      await queryData(false);
      extra++;
      if (aiEnabled) _aiTopUpUsed++;
      final after = _currentLength;
      if (after == current) break;
      current = after;
    }
  }

  int get _currentLength => switch (loadingState.value) {
    Success(:final response) => response?.length ?? 0,
    _ => 0,
  };

  @override
  Future<LoadingState> customGetData() {
    if (!aiEnabled) {
      return _fetchUpstream(page);
    }
    if (page == 0) return _refreshWithAi();
    return _loadMoreWithAi();
  }

  Future<LoadingState> _fetchUpstream(int index) {
    return appRcmd
        ? VideoHttp.rcmdVideoListApp(freshIdx: index)
        : VideoHttp.rcmdVideoList(freshIdx: index, ps: 20);
  }

  Future<LoadingState> _refreshWithAi() async {
    final settings = _ai.settings;
    final token = _aiSession.begin();
    _aiToken = token;
    _aiTopUpUsed = 0;
    _restoredLoadMoreGate = false;
    aiRestoredFolded.value = 0;
    aiNewRankingReady.value = false;
    aiBlockedReason.value = '';
    // A restored page stays on screen until this refresh produces a new one,
    // so a failed start-up refresh does not flash "local rules" over cards
    // that are still visible. The maps are only kept for that single
    // hand-over; the next refresh clears them normally.
    final keepRestored = _feedRestored;
    if (!keepRestored) {
      aiPage.value = null;
      _featuresByBvid.clear();
      _modelsByBvid.clear();
    }
    _seenBvids.clear();
    _allCandidates.clear();

    final source = appRcmd ? 'app' : 'web';
    final accountScope = _ai.recommendScope;
    final signature = settings.toJson();
    final prepared = _preparedAi;
    _preparedAi = null;

    // A page that was fetched and scored by the background worker. The
    // refresh itself performs no model request; it only hands over the
    // already-ranked result.
    if (prepared != null &&
        prepared.signature == signature &&
        prepared.accountScope == accountScope &&
        prepared.source == source &&
        prepared.cursor > 0) {
      page = prepared.cursor;
      _allCandidates.addAll(prepared.models);
      for (final model in prepared.models) {
        final bvid = model.bvid;
        if (bvid != null && bvid.isNotEmpty) {
          _seenBvids.add(bvid);
          _modelsByBvid[bvid] = model;
        }
      }
      for (final feature in AiRecommendationPipeline.featuresOf(
        prepared.models,
        source,
      )) {
        _featuresByBvid[feature.bvid] = feature;
      }
      aiPage.value = prepared.page;
      final now = DateTime.now().millisecondsSinceEpoch;
      final display = <BaseRcmdVideoItemModel>[];
      for (final item in prepared.page.items) {
        final model = _modelsByBvid[item.features.bvid];
        if (model == null) continue;
        display.add(model);
        _lastShownAtMs[item.features.bvid] = now;
      }
      _aiPaintedLength = display.length;
      _feedRestored = false;
      _scheduleAiPrefetch();
      unawaited(_persistFeedSnapshot(display, prepared.page));
      return Success<List<BaseRcmdVideoItemModel>>(display);
    }

    // Strict mode needs enough candidates before it can filter; preference
    // mode keeps the existing six-card top-up path and one upstream page here.
    final pages = settings.mode == AiRecommendMode.strict ? 3 : 1;
    final merged = <BaseRcmdVideoItemModel>[];
    var reachedEnd = false;
    var fetched = 0;

    for (var i = 0; i < pages; i++) {
      final res = await _fetchUpstream(i);
      if (res is Error) {
        if (merged.isEmpty) return res;
        break;
      }
      if (res is! Success) break;
      final list =
          (res.response as List?)?.cast<BaseRcmdVideoItemModel>() ??
          const <BaseRcmdVideoItemModel>[];
      fetched++;
      if (list.isEmpty) {
        reachedEnd = true;
        break;
      }
      for (final item in list) {
        final bvid = item.bvid;
        if (bvid != null && bvid.isNotEmpty && !_seenBvids.add(bvid)) {
          continue;
        }
        merged.add(item);
        if (bvid != null) _modelsByBvid[bvid] = item;
      }
      if (list.length < 20) {
        reachedEnd = true;
        break;
      }
    }

    if (fetched > 0) page = fetched - 1;
    if (settings.mode == AiRecommendMode.strict) {
      _aiTopUpUsed = reachedEnd ? HomeFeedPolicy.maxTopUpPages : fetched;
    }
    if (merged.isEmpty) {
      _feedRestored = false;
      return const Success<List<BaseRcmdVideoItemModel>>([]);
    }
    _allCandidates.addAll(merged);

    // No prepared page yet. Apply only scores that are already cached: the
    // refresh must not start a model request; the worker prepares the next
    // page in the background.
    final ranked = await _ai.pipeline.rankPage(
      models: merged,
      source: source,
      accountScope: accountScope,
      token: token,
      isCurrent: () => _aiSession.isCurrent(token),
      lastShownAtMs: _lastShownAtMs,
      cacheOnly: true,
    );
    if (!_aiSession.isCurrent(token)) {
      return const Success<List<BaseRcmdVideoItemModel>>([]);
    }
    aiPage.value = ranked;
    for (final feature in AiRecommendationPipeline.featuresOf(merged, source)) {
      _featuresByBvid[feature.bvid] = feature;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final models = <BaseRcmdVideoItemModel>[];
    for (final item in ranked.items) {
      final model = _modelsByBvid[item.features.bvid];
      if (model == null) continue;
      models.add(model);
      _lastShownAtMs[item.features.bvid] = now;
    }
    _aiPaintedLength = models.length;
    _feedRestored = false;
    _scheduleAiPrefetch();
    unawaited(_persistFeedSnapshot(models, ranked));
    return Success<List<BaseRcmdVideoItemModel>>(models);
  }

  Future<void> _persistFeedSnapshot(
    List<BaseRcmdVideoItemModel> shown,
    AiRankedPage page,
  ) async {
    final store = _snapshotStore;
    if (store == null || !aiEnabled || shown.isEmpty) return;
    try {
      final snapshot = captureFeedSnapshot(
        visible: shown,
        page: page,
        modelsByBvid: _modelsByBvid,
        source: appRcmd ? 'app' : 'web',
        accountHash: aiFeedFingerprint(_ai.recommendScope),
        settingsHash: aiFeedFingerprint(_ai.settings.toJson()),
        savedAt: DateTime.now(),
      );
      if (snapshot == null) return;
      await store.write(snapshot);
      _warmFeedCovers(shown);
    } catch (_) {
      // The snapshot is derived cache. Failing to write it must not fail the
      // refresh that the user is waiting for.
    }
  }

  /// Puts the next covers on disk before the next cold start asks for them.
  /// NetworkImgLayer looks the same URL up in the same cache manager, so a
  /// restored card can paint its cover instead of its placeholder.
  void _warmFeedCovers(List<BaseRcmdVideoItemModel> shown) {
    final covers = <String>[];
    for (final model in shown) {
      final cover = model.cover;
      if (cover == null || cover.isEmpty || !_warmedCoverUrls.add(cover)) {
        continue;
      }
      covers.add(cover);
      // The snapshot keeps up to this many cards; warm the same set so a
      // restored page can paint its covers without a fresh download.
      if (covers.length >= AiFeedSnapshot.maxVisibleItems) break;
    }
    if (covers.isEmpty) return;
    unawaited(() async {
      try {
        final manager = CacheManager.manager;
        for (final cover in covers) {
          try {
            await manager.getSingleFile(ImageUtils.thumbnailUrl(cover));
          } catch (_) {
            // A cover that cannot be fetched now is simply retried by the
            // widget when the card is displayed.
          }
        }
      } catch (_) {
        // Cache manager not initialized (tests); the widget will fetch it.
      }
    }());
  }

  /// Scores the cards currently on screen, then fetches and scores the next
  /// page for a later refresh. The refresh never waits for this work: it
  /// paints from cache first and [ _applyRankedNow ] drops the freshly scored
  /// order in as soon as the model answers.
  void _scheduleAiPrefetch() {
    if (!aiEnabled) return;
    if (_preparingAi) {
      // A refresh landed while the worker was still busy: run again once the
      // current pass finishes so the new page is scored too.
      _prefetchQueued = true;
      return;
    }
    final settings = _ai.settings;
    final source = appRcmd ? 'app' : 'web';
    final accountScope = _ai.recommendScope;
    final signature = settings.toJson();
    final startCursor = page + 1;
    final epoch = _prefetchEpoch;
    _preparingAi = true;
    unawaited(() async {
      var lastCursor = startCursor;
      try {
        // Score what the user is looking at before preparing the next page.
        // A page prepared ahead of time is only consumed by a later refresh,
        // so waiting for it left the bar on "local rules" while the model was
        // already answering for cards that were not on screen.
        final onScreen = List<BaseRcmdVideoItemModel>.of(_allCandidates);
        final screenToken = _aiToken;
        if (onScreen.isNotEmpty && screenToken != null) {
          final screenSettings = settings.copyWith(
            firstPaintBudgetMs: 30000,
            requestTimeoutMs: 30000,
            maxBatchesPerRefresh: 3,
          );
          final rankedNow = await _ai.pipeline.rankPage(
            models: onScreen,
            source: source,
            accountScope: accountScope,
            token: screenToken,
            isCurrent: () =>
                epoch == _prefetchEpoch && _aiSession.isCurrent(screenToken),
            lastShownAtMs: _lastShownAtMs,
            settingsOverride: screenSettings,
            waitForAi: true,
          );
          if (epoch != _prefetchEpoch) return;
          if (!_aiSession.isCurrent(screenToken)) return;
          if (rankedNow.freshScores > 0) {
            aiBlockedReason.value = '';
            _applyRankedNow(rankedNow);
            return;
          }
          if (rankedNow.cacheHits == 0 && rankedNow.statusDetail.isNotEmpty) {
            // Nothing cached and nothing fresh: the next page would hit the
            // same wall, so report it instead of retrying quietly.
            aiBlockedReason.value = rankedNow.statusDetail;
            return;
          }
        }
        final pages = settings.mode == AiRecommendMode.strict ? 3 : 1;
        final models = <BaseRcmdVideoItemModel>[];
        final seen = <String>{};
        for (var i = 0; i < pages; i++) {
          final cursor = startCursor + i;
          final res = await _fetchUpstream(cursor);
          if (res is! Success) break;
          final list =
              (res.response as List?)?.cast<BaseRcmdVideoItemModel>() ??
              const <BaseRcmdVideoItemModel>[];
          if (list.isEmpty) break;
          lastCursor = cursor;
          for (final item in list) {
            final bvid = item.bvid;
            if (bvid != null && bvid.isNotEmpty && !seen.add(bvid)) {
              continue;
            }
            models.add(item);
          }
          if (list.length < 20) break;
        }
        if (models.isEmpty || epoch != _prefetchEpoch) return;

        final prefetchSettings = settings.copyWith(
          firstPaintBudgetMs: 30000,
          requestTimeoutMs: 30000,
          maxBatchesPerRefresh: 1,
        );
        final ranked = await _ai.pipeline.rankPage(
          models: models,
          source: source,
          accountScope: accountScope,
          token: RecommendationToken(0),
          isCurrent: () => epoch == _prefetchEpoch,
          settingsOverride: prefetchSettings,
          waitForAi: true,
        );
        if (epoch != _prefetchEpoch) return;
        if (ranked.freshScores == 0 && ranked.cacheHits == 0) {
          // The worker produced nothing usable: budget used up, key rejected,
          // model unreachable. Say so instead of silently staying on local
          // rules until the user gives up on the feature.
          aiBlockedReason.value = ranked.statusDetail.isNotEmpty
              ? ranked.statusDetail
              : ranked.status.label;
          return;
        }
        aiBlockedReason.value = '';
        if (signature != _ai.settings.toJson()) return;
        if (source != (appRcmd ? 'app' : 'web') ||
            accountScope != _ai.recommendScope) {
          return;
        }
        _preparedAi = _PreparedAiPage(
          cursor: lastCursor,
          models: models,
          page: ranked,
          signature: signature,
          accountScope: accountScope,
          source: source,
        );
      } catch (e) {
        // Background best effort; the next refresh falls back to local rules.
        // Keep the reason so the status bar can explain the fallback.
        aiBlockedReason.value = '后台评分失败：$e';
      } finally {
        _preparingAi = false;
        if (_prefetchQueued) {
          _prefetchQueued = false;
          _scheduleAiPrefetch();
        }
      }
    }());
  }

  /// Hands a freshly scored page to the screen without another upstream
  /// fetch or model call. Reordering in place is only safe while the feed is
  /// exactly as it was painted: once the user scrolled or refreshed, the new
  /// order is offered for confirmation instead.
  void _applyRankedNow(AiRankedPage ranked) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final models = <BaseRcmdVideoItemModel>[];
    for (final item in ranked.items) {
      final model = _modelsByBvid[item.features.bvid];
      if (model == null) continue;
      models.add(model);
      _lastShownAtMs[item.features.bvid] = now;
    }
    if (models.isEmpty) return;
    if (loadingState.value case Success(:final response)) {
      if (response == null || response.length != _aiPaintedLength) {
        aiNewRankingReady.value = true;
        return;
      }
      aiPage.value = ranked;
      aiNewRankingReady.value = false;
      response
        ..clear()
        ..addAll(models);
      loadingState.refresh();
      _aiPaintedLength = models.length;
      unawaited(_persistFeedSnapshot(models, ranked));
      return;
    }
    aiNewRankingReady.value = true;
  }

  Future<LoadingState> _loadMoreWithAi() async {
    if (_preparedAi != null && _preparedAi!.cursor <= page + 1) {
      _preparedAi = null;
    }
    final settings = _ai.settings;
    final token = _aiToken;
    if (token == null) return _loadMoreWithoutAi();
    var cursor = page;
    for (var attempt = 0; attempt < 2; attempt++) {
      final res = await _fetchUpstream(cursor);
      cursor++;
      if (res is Error) return res;
      if (res is! Success) return res;
      final list =
          (res.response as List?)?.cast<BaseRcmdVideoItemModel>() ??
          const <BaseRcmdVideoItemModel>[];
      if (list.isEmpty) {
        page = cursor - 1;
        return const Success<List<BaseRcmdVideoItemModel>>([]);
      }
      final fresh = <BaseRcmdVideoItemModel>[];
      for (final item in list) {
        final bvid = item.bvid;
        if (bvid != null && bvid.isNotEmpty && !_seenBvids.add(bvid)) {
          continue;
        }
        fresh.add(item);
        if (bvid != null) _modelsByBvid[bvid] = item;
      }
      _allCandidates.addAll(fresh);
      page = cursor - 1;
      if (fresh.isEmpty) continue;
      final ranked = await _ai.pipeline.rankPage(
        models: fresh,
        source: appRcmd ? 'app' : 'web',
        accountScope: _ai.recommendScope,
        token: token,
        isCurrent: () => _aiSession.isCurrent(token),
        lastShownAtMs: _lastShownAtMs,
      );
      if (!_aiSession.isCurrent(token)) {
        return const Success<List<BaseRcmdVideoItemModel>>([]);
      }
      for (final feature in AiRecommendationPipeline.featuresOf(
        fresh,
        appRcmd ? 'app' : 'web',
      )) {
        _featuresByBvid[feature.bvid] = feature;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final models = <BaseRcmdVideoItemModel>[];
      for (final item in ranked.items) {
        final model = _modelsByBvid[item.features.bvid];
        if (model == null) continue;
        models.add(model);
        _lastShownAtMs[item.features.bvid] = now;
      }
      // Strict mode can empty one page. Try the next cursor once before
      // reporting the end; the caller never sees a silent dead end.
      if (models.isEmpty && settings.mode == AiRecommendMode.strict) {
        continue;
      }
      return Success<List<BaseRcmdVideoItemModel>>(models);
    }
    return const Success<List<BaseRcmdVideoItemModel>>([]);
  }

  Future<LoadingState> _loadMoreWithoutAi() => _fetchUpstream(page);

  @override
  bool handleError(String? errMsg) {
    // Swallowing the error is only right when there is something to keep on
    // screen: the saved last-session cards. On the first load of a session
    // there are none, and returning true here left the feed on its skeleton
    // with no message and no retry - the screen simply never filled. That is
    // what "首页看不到内容" looks like from the outside.
    // Cached cards restored at start-up are just as worth keeping as the
    // in-memory saved list: the user already saw them before the refresh.
    if (!enableSaveLastData && !_feedRestored) return false;
    if (loadingState.value case Success(:final response)) {
      return response != null && response.isNotEmpty;
    }
    return false;
  }

  @override
  void handleListResponse(List dataList) {
    // Saved last-session cards were never scored by AI; appending them would
    // mix unscored cards into a strict list.
    if (aiEnabled) return;
    if (enableSaveLastData && page == 0) {
      if (loadingState.value case Success(:final response)) {
        if (response != null && response.isNotEmpty) {
          if (savedRcmdTip) {
            lastRefreshAt = dataList.length;
          }
          if (response.length > 200) {
            dataList.addAll(response.take(50));
          } else {
            dataList.addAll(response);
          }
        }
      }
    }
  }

  @override
  Future<void> onRefresh() async {
    _aiSession.invalidate();
    _aiToken = null;
    page = 0;
    isEnd = false;
    await queryData();
    await topUpGrid();
    await loadSharedVideos();
  }

  Future<void> aiFeedback(String bvid, FeedbackKind kind) async {
    final feature = _featuresByBvid[bvid];
    if (feature == null) return;
    final topics = aiPage.value?.scores[bvid]?.topics ?? const <String>[];
    final ok = await _ai.recordFeedback(
      features: feature,
      kind: kind,
      modelTopics: topics,
    );
    SmartDialog.showToast(
      ok ? '已更新本地 AI 偏好，下次刷新生效' : 'AI 推荐筛选未开启',
    );
  }

  /// Applies already-cached scores to the candidates currently on screen.
  /// No upstream page is fetched and no new model request is made, so the
  /// scores that just arrived are not thrown away by a refresh.
  Future<void> applyLateAiRanking() async {
    final token = _aiToken;
    if (token == null || _allCandidates.isEmpty) return;
    final ranked = await _ai.pipeline.rankPage(
      models: List<BaseRcmdVideoItemModel>.of(_allCandidates),
      source: appRcmd ? 'app' : 'web',
      accountScope: _ai.recommendScope,
      token: token,
      isCurrent: () => _aiSession.isCurrent(token),
      lastShownAtMs: _lastShownAtMs,
      cacheOnly: true,
    );
    if (!_aiSession.isCurrent(token)) return;
    aiPage.value = ranked;
    aiNewRankingReady.value = false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final models = <BaseRcmdVideoItemModel>[];
    for (final item in ranked.items) {
      final model = _modelsByBvid[item.features.bvid];
      if (model == null) continue;
      models.add(model);
      _lastShownAtMs[item.features.bvid] = now;
    }
    if (loadingState.value case Success(:final response)) {
      response!
        ..clear()
        ..addAll(models);
      loadingState.refresh();
    } else {
      loadingState.value = Success<List<BaseRcmdVideoItemModel>>(models);
    }
    _aiPaintedLength = models.length;
    unawaited(_persistFeedSnapshot(models, ranked));
  }

  Future<void> aiUndo() async {
    final ok = await _ai.undoLastFeedback();
    SmartDialog.showToast(ok ? '已撤销最近一次反馈' : '没有可撤销的反馈');
  }

  void restoreFolded() {
    final pageData = aiPage.value;
    if (pageData == null || pageData.folded.isEmpty) return;
    final models = <BaseRcmdVideoItemModel>[];
    for (final item in pageData.folded) {
      final model = _modelsByBvid[item.features.bvid];
      if (model != null) models.add(model);
    }
    if (models.isEmpty) return;
    if (loadingState.value case Success(:final response)) {
      response!.addAll(models);
      loadingState.refresh();
    }
    aiRestoredFolded.value = aiRestoredFolded.value + models.length;
  }

  void openAiSettings() {
    Get.to(() => const AiRecommendSettingsPage());
  }

  @override
  void onClose() {
    _prefetchEpoch++;
    _aiSession.invalidate();
    super.onClose();
  }
}
