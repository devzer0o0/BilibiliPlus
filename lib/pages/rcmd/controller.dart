import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/msg/shared_video.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/utils/home_feed_policy.dart';
import 'package:PiliPlus/utils/shared_video_read_store.dart';
import 'package:PiliPlus/utils/shared_video_service.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:get/get.dart';

class RcmdController extends CommonListController {
  late bool enableSaveLastData = Pref.enableSaveLastData;
  final bool appRcmd = Pref.appRcmd;

  int? lastRefreshAt;
  late bool savedRcmdTip = Pref.savedRcmdTip;

  /// Videos shared over private messages, newest first, minus what was opened.
  /// Shown above the grid and deliberately not counted towards its six.
  final RxList<SharedVideo> sharedVideos = <SharedVideo>[].obs;

  @override
  bool get isEnd => false;

  @override
  void onInit() {
    super.onInit();
    page = 0;
    queryData();
    loadSharedVideos();
  }

  /// Refreshes the shared section. Failures are swallowed: a private-message
  /// problem must not stop the recommendation feed from loading.
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

  /// Called once the user opens a share; it leaves the section for good.
  Future<void> onSharedVideoOpened(String bvid) async {
    await SharedVideoReadStore.markOpened(bvid);
    sharedVideos.removeWhere((v) => v.bvid == bvid);
  }

  /// Fetches more pages until the grid holds [HomeFeedPolicy.target] cards.
  /// Bounded and end-aware; see [HomeFeedPolicy.needsMore].
  Future<void> topUpGrid() async {
    var extra = 0;
    var current = _currentLength;
    while (HomeFeedPolicy.needsMore(
      currentLength: current,
      fetchedPages: extra,
      atEnd: isEnd,
    )) {
      await queryData(false);
      extra++;
      final after = _currentLength;
      // A page that changed nothing means there was nothing more to get.
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
    return appRcmd
        ? VideoHttp.rcmdVideoListApp(freshIdx: page)
        : VideoHttp.rcmdVideoList(freshIdx: page, ps: 20);
  }

  @override
  bool handleError(String? errMsg) {
    return enableSaveLastData;
  }

  @override
  void handleListResponse(List dataList) {
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
    page = 0;
    isEnd = false;
    await queryData();
    // A refresh can legitimately return fewer than six cards; top the grid back
    // up rather than leaving a short page.
    await topUpGrid();
    await loadSharedVideos();
  }
}
