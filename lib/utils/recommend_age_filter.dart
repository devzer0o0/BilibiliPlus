import 'package:flutter/foundation.dart';

/// How far back the recommendation feed is allowed to reach.
///
/// A `null` window means "do not filter", which is the pre-existing behaviour:
/// the switch exists so that turning the feature off restores exactly what the
/// feed did before, rather than approximating it.
///
/// The list is ordered so new rungs can be inserted without renumbering the
/// stored value - [RecommendAgeFilter] persists [days], not an index, so a
/// setting saved yesterday still means the same thing after a rung is added.
enum RecommendAgeFilter {
  all(null, '不限'),
  week(7, '最近 7 天'),
  month(30, '最近 1 个月'),
  quarter(90, '最近 3 个月'),
  halfYear(180, '最近半年'),
  year(365, '最近 1 年'),

  /// A cutoff the user picks directly instead of a fixed window. It carries no
  /// day count: the date is stored beside the filter (passed to
  /// [RecommendAgeWindow.of] as `customAfter`). A missing date leaves the feed
  /// unfiltered rather than hiding everything.
  custom(null, '自定义时间');

  const RecommendAgeFilter(this.days, this.label);

  /// Window length in days, or null for no filtering.
  final int? days;

  /// User-facing label. Kept next to the value so a new rung cannot ship
  /// without one.
  final String label;

  /// Whether this rung filters anything at all. [custom] counts as enabled even
  /// before a date is stored, so the settings row can offer to pick one.
  bool get isEnabled => this != all;

  bool get isCustom => this == custom;

  /// Persisted form. Storing the day count keeps the meaning stable when the
  /// rung list changes; 0 means "no filter" and [customStoredValue] means the
  /// cutoff comes from the stored date. A build that predates [custom] reads
  /// the sentinel as "no filter", which is the safe direction.
  int get storedValue => isCustom ? customStoredValue : (days ?? 0);

  /// Marker for [custom]; distinct from 0 and from every positive day count.
  static const int customStoredValue = -2;

  static RecommendAgeFilter fromStored(int? stored) {
    if (stored == customStoredValue) return custom;
    if (stored == null || stored <= 0) return all;
    for (final filter in values) {
      if (filter.days == stored) return filter;
    }
    // An unknown stored value is a rung this build no longer has. Falling back
    // to `all` is the safe direction: showing more is recoverable, hiding
    // everything is not.
    return all;
  }
}

/// The published-after boundary for one filter, in Unix seconds.
///
/// Pure so the rule is assertable without a clock or a store: the caller passes
/// `now`, and an unsupported or disabled filter yields null.
@immutable
class RecommendAgeWindow {
  const RecommendAgeWindow._(this.afterSeconds);

  /// Cutoff in Unix seconds, or null when nothing should be filtered.
  final int? afterSeconds;

  bool get isActive => afterSeconds != null;

  ///
  /// [customAfter] is the cutoff for [RecommendAgeFilter.custom] and is ignored
  /// by the fixed rungs. A custom filter without a date yields an inactive
  /// window: showing more is recoverable, hiding the feed is not.
  factory RecommendAgeWindow.of(
    RecommendAgeFilter filter, {
    DateTime? now,
    DateTime? customAfter,
  }) {
    if (filter.isCustom) {
      final after = customAfter;
      if (after == null) return const RecommendAgeWindow._(null);
      return RecommendAgeWindow._(after.millisecondsSinceEpoch ~/ 1000);
    }
    final days = filter.days;
    if (days == null) return const RecommendAgeWindow._(null);
    final from = (now ?? DateTime.now()).subtract(Duration(days: days));
    return RecommendAgeWindow._(from.millisecondsSinceEpoch ~/ 1000);
  }

  /// Whether a video is inside the window.
  ///
  /// [pubdate] is Unix seconds, as the catalogue reports it. A null or zero
  /// value means the feed did not date this item: it is **kept**, because
  /// dropping every undated entry would empty a feed during an API change and
  /// would look exactly like "the filter is broken". A video dated in the
  /// future (clock skew between this device and the server) is also kept - it is
  /// inside the window by definition of "after".
  bool allows(int? pubdate) {
    final cutoff = afterSeconds;
    if (cutoff == null) return true;
    if (pubdate == null || pubdate <= 0) return true;
    return pubdate >= cutoff;
  }
}
