import 'package:PiliPlus/models/common/msg/shared_video.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';

/// Tracks which shared videos the user has already opened.
///
/// The home feed shows shared videos until they are opened; without this the
/// same entry would sit there forever. Persisted as a plain bvid list in the
/// setting box, capped so it cannot grow without bound.
abstract final class SharedVideoReadStore {
  /// Keeps the newest N; older ids are dropped. A share older than this many
  /// opens is almost certainly gone from the feed anyway.
  static const int maxRemembered = 200;

  static List<String> get _raw {
    final stored = GStorage.setting.get(
      SettingBoxKey.openedSharedVideos,
      defaultValue: const <String>[],
    );
    return stored is List ? stored.whereType<String>().toList() : <String>[];
  }

  static Set<String> get opened => _raw.toSet();

  static bool hasOpened(String bvid) => opened.contains(bvid);

  /// Records [bvid] as opened and returns the list it kept.
  static Future<void> markOpened(String bvid) async {
    if (bvid.isEmpty) return;
    final list = _raw..remove(bvid);
    list.insert(0, bvid);
    if (list.length > maxRemembered) {
      list.removeRange(maxRemembered, list.length);
    }
    await GStorage.setting.put(SettingBoxKey.openedSharedVideos, list);
  }

  /// Drops [bvid] from the opened set, so it shows again.
  static Future<void> markUnopened(String bvid) async {
    final list = _raw..remove(bvid);
    await GStorage.setting.put(SettingBoxKey.openedSharedVideos, list);
  }

  /// The shares still worth showing, newest first.
  static List<SharedVideo> visible(List<SharedVideo> all) {
    final seen = opened;
    return all.where((v) => !seen.contains(v.bvid)).toList();
  }
}
