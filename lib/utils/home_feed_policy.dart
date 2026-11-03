import 'package:PiliPlus/models/common/msg/shared_video.dart';

/// Rules for the home recommendation grid.
///
/// The grid wants exactly [target] normal cards. Shared videos are shown *above*
/// it and are excluded from that count, because they are a separate section with
/// their own dismissal rule.
abstract final class HomeFeedPolicy {
  /// How many recommendation cards the grid should hold.
  static const int target = 6;

  /// How many pages the controller may fetch while topping the grid up.
  ///
  /// Bounded on purpose: the recommendation endpoint can legitimately return
  /// fewer entries than asked for (end of the feed, heavy filtering), and
  /// retrying forever would hammer the API on every refresh.
  static const int maxTopUpPages = 3;

  /// Whether another page should be requested to reach [target].
  ///
  /// [fetchedPages] counts the extra pages already spent on this top-up, so the
  /// caller passes 0 on the first attempt.
  static bool needsMore({
    required int currentLength,
    required int fetchedPages,
    required bool atEnd,
  }) =>
      currentLength < target && fetchedPages < maxTopUpPages && !atEnd;

  /// The recommendation cards to show: the first [target], in order.
  ///
  /// Truncating here rather than at fetch time keeps the controller simple and
  /// makes the "exactly six" rule visible in one place.
  static List<T> grid<T>(List<T> items) =>
      items.length <= target ? items : items.sublist(0, target);

  /// Shared videos still worth showing, minus anything already opened.
  static List<SharedVideo> sharedSection(List<SharedVideo> all, Set<String> opened) =>
      all.where((v) => !opened.contains(v.bvid)).toList();
}
