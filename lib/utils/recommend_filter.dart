import 'package:PiliPlus/models/model_video.dart';
import 'package:PiliPlus/utils/recommend_age_filter.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

abstract final class RecommendFilter {
  static int minDurationForRcmd = Pref.minDurationForRcmd;
  static int minPlayForRcmd = Pref.minPlayForRcmd;
  static int minLikeRatioForRecommend = Pref.minLikeRatioForRecommend;
  static bool exemptFilterForFollowed = Pref.exemptFilterForFollowed;
  static bool applyFilterToRelatedVideos = Pref.applyFilterToRelatedVideos;
  static RegExp rcmdRegExp = RegExp(
    Pref.banWordForRecommend,
    caseSensitive: false,
  );
  static bool enableFilter = rcmdRegExp.pattern.isNotEmpty;

  /// How far back the feed may reach. `all` means the switch is off, which is
  /// the behaviour every other filter here already had.
  ///
  /// Lazily resolved: this class is first touched from the HTTP layer, which can
  /// run before Hive is open. A static initialiser would read `Pref` at class
  /// load and throw. Null means "not read yet", not "no filter".
  static RecommendAgeFilter? _ageFilter;

  static RecommendAgeFilter get ageFilter =>
      _ageFilter ??= _readStoredAgeFilter();

  static set ageFilter(RecommendAgeFilter value) => _ageFilter = value;

  /// Cutoff for [RecommendAgeFilter.custom], or null when no date was picked.
  ///
  /// Null is also what a cold path sees before storage is open, so a custom
  /// filter there hides nothing instead of hiding everything. Cached with an
  /// explicit loaded flag because null is a meaningful cached value too.
  static DateTime? _customAgeAfter;
  static bool _customAgeAfterLoaded = false;

  static DateTime? get customAgeAfter {
    if (!_customAgeAfterLoaded) {
      _customAgeAfterLoaded = true;
      _customAgeAfter = _readStoredCustomAgeAfter();
    }
    return _customAgeAfter;
  }

  static set customAgeAfter(DateTime? value) {
    _customAgeAfterLoaded = true;
    _customAgeAfter = value;
  }

  static DateTime? _readStoredCustomAgeAfter() {
    try {
      final millis = Pref.rcmdAgeFilterCustomAfter;
      if (millis <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(millis);
    } catch (_) {
      return null;
    }
  }

  /// Reads the stored window, tolerating a store that is not open yet.
  ///
  /// This class is reached from the HTTP layer, and `GStorage.setting` is a late
  /// field that only exists after `GStorage.init()`; reading it earlier throws
  /// `LateInitializationError`. Returning `all` is the correct fallback: it is
  /// the behaviour this build had before the option existed, and it filters
  /// nothing, so a cold path cannot hide content.
  static RecommendAgeFilter _readStoredAgeFilter() {
    try {
      return RecommendAgeFilter.fromStored(Pref.rcmdAgeFilterDays);
    } catch (_) {
      return RecommendAgeFilter.all;
    }
  }

  /// Injectable clock for the cutoff. Production leaves it null; tests set it so
  /// the window is deterministic.
  static DateTime? nowOverride;

  static RecommendAgeWindow get ageWindow => RecommendAgeWindow.of(
    ageFilter,
    now: nowOverride,
    customAfter: customAgeAfter,
  );

  // (web/app)rcmd
  /// Re-reads the static mirrors after a restore or settings import.
  ///
  /// The fields above are intentionally fast to read on every card; a restore
  /// writes Hive directly and must refresh them or the UI keeps the old rules.
  static void reload() {
    minDurationForRcmd = Pref.minDurationForRcmd;
    minPlayForRcmd = Pref.minPlayForRcmd;
    minLikeRatioForRecommend = Pref.minLikeRatioForRecommend;
    exemptFilterForFollowed = Pref.exemptFilterForFollowed;
    applyFilterToRelatedVideos = Pref.applyFilterToRelatedVideos;
    rcmdRegExp = RegExp(Pref.banWordForRecommend, caseSensitive: false);
    enableFilter = rcmdRegExp.pattern.isNotEmpty;
  }

  static bool filterWithExempt(BaseVideoItemModel videoItem) {
    //由于相关视频中没有已关注标签，只能视为非关注视频
    if (videoItem.isFollowed && exemptFilterForFollowed) {
      return false;
    }
    return filterAll(videoItem);
  }

  /// hot/rank/[filterAll]
  static bool filterLikeRatio(int? like, int? view) {
    if (view != null) {
      return (view > -1 && view < minPlayForRcmd) ||
          (like != null &&
              like > -1 &&
              like * 100 < minLikeRatioForRecommend * view);
    }
    return false;
  }

  /// hot/rank/[filterAll]
  static bool filterTitle(String title) {
    return (enableFilter && rcmdRegExp.hasMatch(title));
  }

  /// [filterAll]
  static bool filterDuration(int duration) {
    return duration > 0 && duration < minDurationForRcmd;
  }

  /// Whether [pubdate] falls outside the selected age window.
  ///
  /// Split out from [filterAll] so a caller holding only a raw timestamp (the
  /// app-recommend path parses maps, not models) can apply the same rule.
  static bool filterAge(int? pubdate) => !ageWindow.allows(pubdate);

  /// related/[filterWithExempt]
  static bool filterAll(BaseVideoItemModel videoItem) {
    return filterDuration(videoItem.duration) ||
        filterAge(videoItem.pubdate) ||
        filterLikeRatio(videoItem.stat.like, videoItem.stat.view) ||
        filterTitle(videoItem.title);
  }
}
