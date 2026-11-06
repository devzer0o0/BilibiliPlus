import 'package:PiliPlus/utils/recommend_age_filter.dart';
import 'package:PiliPlus/utils/recommend_filter.dart';
import 'package:flutter_test/flutter_test.dart';

/// The age filter decides what a user never sees, so the edges matter more than
/// the happy path: an undated item, a future timestamp, a stored value this
/// build no longer knows.
void main() {
  // A fixed clock keeps the window arithmetic deterministic; the production
  // default is DateTime.now().
  final now = DateTime.utc(2026, 11, 5, 12);
  int at(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

  group('the window is a cutoff, not a bucket', () {
    test('a video inside the last 7 days is allowed', () {
      final window = RecommendAgeWindow.of(RecommendAgeFilter.week, now: now);
      expect(window.allows(at(now.subtract(const Duration(days: 3)))), isTrue);
    });

    test('a video older than 7 days is refused', () {
      final window = RecommendAgeWindow.of(RecommendAgeFilter.week, now: now);
      expect(window.allows(at(now.subtract(const Duration(days: 8)))), isFalse);
    });

    test('the boundary itself is allowed', () {
      final window = RecommendAgeWindow.of(RecommendAgeFilter.week, now: now);
      final edge = now.subtract(const Duration(days: 7));
      expect(window.allows(at(edge)), isTrue);
    });

    test('one month reaches further than one week', () {
      final week = RecommendAgeWindow.of(RecommendAgeFilter.week, now: now);
      final month = RecommendAgeWindow.of(RecommendAgeFilter.month, now: now);
      final twentyDaysAgo = at(now.subtract(const Duration(days: 20)));
      expect(week.allows(twentyDaysAgo), isFalse);
      expect(month.allows(twentyDaysAgo), isTrue);
    });
  });

  group('"all" is the pre-existing behaviour', () {
    test('every date is allowed when the filter is off', () {
      final window = RecommendAgeWindow.of(RecommendAgeFilter.all, now: now);
      expect(window.isActive, isFalse);
      expect(window.allows(null), isTrue);
      expect(window.allows(0), isTrue);
      expect(
        window.allows(at(now.subtract(const Duration(days: 9999)))),
        isTrue,
      );
    });
  });

  group('an undated item is kept, not dropped', () {
    test('null pubdate survives an active window', () {
      // Dropping every undated entry would empty the feed during an API change
      // and look exactly like a broken filter.
      final window = RecommendAgeWindow.of(RecommendAgeFilter.week, now: now);
      expect(window.allows(null), isTrue);
      expect(window.allows(0), isTrue);
    });

    test('a future timestamp survives', () {
      // Clock skew between this device and the server must not hide a video.
      final window = RecommendAgeWindow.of(RecommendAgeFilter.week, now: now);
      expect(window.allows(at(now.add(const Duration(hours: 2)))), isTrue);
    });
  });

  group('the stored value keeps its meaning', () {
    test('days are persisted, not an index', () {
      // Adding a rung later must not change what an existing setting means.
      expect(RecommendAgeFilter.week.storedValue, 7);
      expect(RecommendAgeFilter.month.storedValue, 30);
      expect(RecommendAgeFilter.all.storedValue, 0);
    });

    test('a stored value round-trips', () {
      for (final filter in RecommendAgeFilter.values) {
        expect(
          RecommendAgeFilter.fromStored(filter.storedValue),
          filter,
          reason: filter.label,
        );
      }
    });

    test('an unknown stored value falls back to no filtering', () {
      // Showing more is recoverable; hiding everything is not.
      expect(RecommendAgeFilter.fromStored(12345), RecommendAgeFilter.all);
      expect(RecommendAgeFilter.fromStored(null), RecommendAgeFilter.all);
      expect(RecommendAgeFilter.fromStored(-1), RecommendAgeFilter.all);
    });
  });

  group('a custom cutoff is the date the user picked', () {
    final cutoff = DateTime.utc(2025, 6, 1);

    RecommendAgeWindow customWindow(DateTime? after) => RecommendAgeWindow.of(
      RecommendAgeFilter.custom,
      now: now,
      customAfter: after,
    );

    test('the custom rung counts as enabled', () {
      expect(RecommendAgeFilter.custom.isEnabled, isTrue);
      expect(RecommendAgeFilter.all.isEnabled, isFalse);
    });

    test('a video after the picked date is allowed', () {
      expect(
        customWindow(cutoff).allows(at(cutoff.add(const Duration(days: 1)))),
        isTrue,
      );
    });

    test('a video before the picked date is refused', () {
      expect(
        customWindow(
          cutoff,
        ).allows(at(cutoff.subtract(const Duration(seconds: 1)))),
        isFalse,
      );
    });

    test('the picked day itself is kept', () {
      expect(customWindow(cutoff).allows(at(cutoff)), isTrue);
    });

    test('the cutoff does not move with the clock', () {
      // Unlike the fixed rungs, "after 2025-06-01" means that date forever.
      final early = RecommendAgeWindow.of(
        RecommendAgeFilter.custom,
        now: DateTime.utc(2026, 1, 1),
        customAfter: cutoff,
      );
      final late = RecommendAgeWindow.of(
        RecommendAgeFilter.custom,
        now: DateTime.utc(2030, 1, 1),
        customAfter: cutoff,
      );
      expect(early.afterSeconds, at(cutoff));
      expect(late.afterSeconds, early.afterSeconds);
    });

    test('custom without a date hides nothing', () {
      final window = customWindow(null);
      expect(window.isActive, isFalse);
      expect(
        window.allows(at(now.subtract(const Duration(days: 9999)))),
        isTrue,
      );
    });
  });

  group('the custom rung round-trips through storage', () {
    test('the marker is persisted and read back', () {
      expect(RecommendAgeFilter.custom.storedValue, isNegative);
      expect(
        RecommendAgeFilter.fromStored(RecommendAgeFilter.custom.storedValue),
        RecommendAgeFilter.custom,
      );
    });

    test('the marker cannot collide with a day count', () {
      for (final filter in RecommendAgeFilter.values) {
        if (filter == RecommendAgeFilter.custom) continue;
        expect(
          filter.storedValue,
          isNot(RecommendAgeFilter.custom.storedValue),
        );
      }
    });

    test('negative values this build does not know still mean no filter', () {
      // A stray sentinel must not be read as "a rung of N days".
      expect(RecommendAgeFilter.fromStored(-1), RecommendAgeFilter.all);
      expect(RecommendAgeFilter.fromStored(-3), RecommendAgeFilter.all);
    });
  });

  group('the rung list is extensible', () {
    test('at least 7 days and 1 month exist', () {
      expect(RecommendAgeFilter.values, contains(RecommendAgeFilter.week));
      expect(RecommendAgeFilter.values, contains(RecommendAgeFilter.month));
    });

    test('every rung has a label and a distinct day count', () {
      final seen = <int>{};
      for (final filter in RecommendAgeFilter.values) {
        expect(filter.label, isNotEmpty);
        final days = filter.days;
        if (days == null) continue;
        expect(seen.add(days), isTrue, reason: 'duplicate days: $days');
      }
    });

    test('rungs are ordered from narrow to wide', () {
      final active = RecommendAgeFilter.values
          .where((f) => f.days != null)
          .map((f) => f.days!)
          .toList();
      final sorted = [...active]..sort();
      expect(active, sorted);
    });
  });

  group('the filter is safe to touch before storage is open', () {
    test('reading the filter does not initialise state eagerly', () {
      // RecommendFilter is reached from the HTTP layer, which can run before
      // Hive is open. A static initialiser there would throw at class load; the
      // getter is lazy instead. Reaching this line without an exception is the
      // assertion - there is no store in a unit test.
      expect(RecommendFilter.ageFilter, isA<RecommendAgeFilter>());
    });

    test('an explicitly set filter wins over storage', () {
      final original = RecommendFilter.ageFilter;
      RecommendFilter.ageFilter = RecommendAgeFilter.week;
      expect(RecommendFilter.ageFilter, RecommendAgeFilter.week);
      RecommendFilter.ageFilter = original;
    });

    test('the window follows the current filter', () {
      final original = RecommendFilter.ageFilter;
      RecommendFilter.ageFilter = RecommendAgeFilter.all;
      expect(RecommendFilter.ageWindow.isActive, isFalse);
      RecommendFilter.ageFilter = RecommendAgeFilter.month;
      expect(RecommendFilter.ageWindow.isActive, isTrue);
      RecommendFilter.ageFilter = original;
    });

    test('filterAge mirrors the window', () {
      final original = RecommendFilter.ageFilter;
      RecommendFilter.ageFilter = RecommendAgeFilter.all;
      expect(RecommendFilter.filterAge(null), isFalse);
      RecommendFilter.ageFilter = original;
    });
  });
}
