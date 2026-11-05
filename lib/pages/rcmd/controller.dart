import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/ai_recommend/ai_card_actions.dart';
import 'package:PiliPlus/models/ai_recommend/ai_recommend_settings.dart';
import 'package:PiliPlus/models/ai_recommend/interest_profile.dart';
import 'package:PiliPlus/models/ai_recommend/video_features.dart';
import 'package:PiliPlus/models/common/msg/shared_video.dart';
import 'package:PiliPlus/models/model_rec_video_item.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/pages/setting/ai_recommend.dart';
import 'package:PiliPlus/utils/ai_recommend/ai_recommendation_service.dart';
import 'package:PiliPlus/utils/ai_recommend/recommendation_pipeline.dart';
import 'package:PiliPlus/utils/home_feed_policy.dart';
import 'package:PiliPlus/utils/shared_video_read_store.dart';
import 'package:PiliPlus/utils/shared_video_service.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

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

  RecommendationToken? _aiToken;
  int _aiTopUpUsed = 0;
  final Map<String, int> _lastShownAtMs = {};
  final Map<String, VideoFeatures> _featuresByBvid = {};
  final Set<String> _seenBvids = {};
  final Map<String, BaseRcmdVideoItemModel> _modelsByBvid = {};

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

  @override
  void onInit() {
    super.onInit();
    page = 0;
    queryData();
    loadSharedVideos();
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
    aiRestoredFolded.value = 0;
    aiNewRankingReady.value = false;
    aiPage.value = null;
    _featuresByBvid.clear();
    _modelsByBvid.clear();
    _seenBvids.clear();

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
      return const Success<List<BaseRcmdVideoItemModel>>([]);
    }

    final ranked = await _ai.pipeline.rankPage(
      models: merged,
      source: appRcmd ? 'app' : 'web',
      accountScope: _ai.recommendScope,
      token: token,
      isCurrent: () => _aiSession.isCurrent(token),
      lastShownAtMs: _lastShownAtMs,
      onLateRankingReady: () {
        aiNewRankingReady.value = true;
      },
    );
    if (!_aiSession.isCurrent(token)) {
      // A refresh, keyword change, account switch or dispose happened while
      // the model was thinking. Return the last known state, never stale cards.
      return const Success<List<BaseRcmdVideoItemModel>>([]);
    }
    aiPage.value = ranked;
    for (final feature in AiRecommendationPipeline.featuresOf(
      merged,
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
    return Success<List<BaseRcmdVideoItemModel>>(models);
  }

  Future<LoadingState> _loadMoreWithAi() async {
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
    if (!enableSaveLastData) return false;
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
    _aiSession.invalidate();
    super.onClose();
  }
}
