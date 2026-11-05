// ignore_for_file: prefer_interpolation_to_compose_strings, unnecessary_lambdas
import 'dart:convert';

import 'package:PiliPlus/models/ai_recommend/ai_recommend_settings.dart';
import 'package:PiliPlus/models/ai_recommend/interest_profile.dart';
import 'package:PiliPlus/models/backup/backup_config.dart';
import 'package:PiliPlus/models/backup/backup_snapshot.dart';
import 'package:PiliPlus/utils/backup/backup_registry.dart';

enum RestoreChangeKind {
  setSetting,
  addToList,
  replaceList,
  replaceProfile,
  installFont,
  replaceAiSettings,
  mergeProgress,
}

class RestoreChange {
  const RestoreChange({
    required this.category,
    required this.key,
    required this.kind,
    required this.oldValue,
    required this.newValue,
  });

  final String category;
  final String key;
  final RestoreChangeKind kind;
  final Object? oldValue;
  final Object? newValue;

  String get label {
    if (kind == RestoreChangeKind.installFont) return '安装字体';
    if (kind == RestoreChangeKind.replaceProfile) return '替换推测兴趣画像';
    if (kind == RestoreChangeKind.replaceAiSettings) return '恢复 AI 明确偏好';
    return key;
  }
}

class RestoreSkip {
  const RestoreSkip({
    required this.category,
    required this.key,
    required this.reason,
  });

  final String category;
  final String key;
  final String reason;
}

class RestorePlan {
  const RestorePlan({
    required this.manifest,
    required this.changes,
    required this.skips,
    required this.selectedCategories,
    required this.requiresRestart,
    required this.notes,
    this.fontFamily,
  });

  final BackupManifest manifest;
  final List<RestoreChange> changes;
  final List<RestoreSkip> skips;
  final List<String> selectedCategories;
  final bool requiresRestart;
  final List<String> notes;
  final String? fontFamily;

  bool get isEmpty => changes.isEmpty;

  int get changeCount => changes.length;
}

typedef RestoreSettingReader = Object? Function(String key);
typedef RestoreStringListReader = List<String> Function();
typedef RestoreIntListReader = List<int> Function();
typedef RestoreProgressReader = Map<String, int> Function();

class RestorePlanner {
  RestorePlanner({
    required this.readSetting,
    required this.readBlacklist,
    required this.readSearchHistory,
    required this.readReplies,
    required this.readWatchProgress,
    required this.readAiSettings,
    required this.readCurrentProfile,
    required this.targetPlatform,
    required this.targetScope,
    required this.currentFontFamily,
  });

  final RestoreSettingReader readSetting;
  final RestoreIntListReader readBlacklist;
  final RestoreStringListReader readSearchHistory;
  final RestoreStringListReader readReplies;
  final RestoreProgressReader readWatchProgress;
  final AiRecommendSettings Function() readAiSettings;
  final Future<InterestProfile?> Function() readCurrentProfile;
  final String targetPlatform;
  final String targetScope;
  final String? currentFontFamily;

  Future<RestorePlan> plan(
    BackupArchive archive, {
    required BackupSelection selection,
    bool mergeLists = false,
  }) async {
    final changes = <RestoreChange>[];
    final skips = <RestoreSkip>[];
    final notes = <String>[
      '账号 Cookie、WebDAV/S3 凭据、AI API Key 和恢复密钥从不进入备份，因此不会被恢复。',
    ];
    var requiresRestart = false;

    for (final entry in archive.categories.entries) {
      final id = entry.key;
      final payload = entry.value;
      final spec = BackupRegistry.byId(id);
      if (spec == null) {
        skips.add(RestoreSkip(category: id, key: '', reason: '未知分类，已跳过'));
        continue;
      }
      if (!selection.includes(id)) {
        skips.add(RestoreSkip(category: id, key: '', reason: '未选择恢复'));
        continue;
      }
      final schema = archive.manifest.schemaVersions[id] ?? 0;
      if (schema > BackupRegistry.schemaVersion) {
        skips.add(
          RestoreSkip(category: id, key: '', reason: '分类版本过新，已跳过'),
        );
        continue;
      }
      if (spec.crossPlatformSkip &&
          archive.manifest.platform.isNotEmpty &&
          archive.manifest.platform != targetPlatform) {
        skips.add(
          RestoreSkip(
            category: id,
            key: '',
            reason: '来源平台为 ' + archive.manifest.platform + '，与当前平台不同，已跳过',
          ),
        );
        continue;
      }

      switch (spec.source) {
        case BackupSource.setting:
        case BackupSource.videoSetting:
          final data = _asMap(payload);
          if (data == null) {
            skips.add(RestoreSkip(category: id, key: '', reason: '内容结构不合法'));
            continue;
          }
          for (final item in data.entries) {
            final key = item.key;
            final value = item.value;
            if (BackupRegistry.isExcludedSettingKey(key)) {
              skips.add(
                RestoreSkip(category: id, key: key, reason: '凭据字段已排除'),
              );
              continue;
            }
            if (!spec.settingKeys.contains(key)) {
              skips.add(
                RestoreSkip(category: id, key: key, reason: '未注册设置，已跳过'),
              );
              continue;
            }
            if (!BackupRegistry.isPortableValue(value)) {
              skips.add(
                RestoreSkip(category: id, key: key, reason: '值类型不支持'),
              );
              continue;
            }
            final old = readSetting(key);
            if (_jsonEquals(old, value)) continue;
            changes.add(
              RestoreChange(
                category: id,
                key: key,
                kind: RestoreChangeKind.setSetting,
                oldValue: old,
                newValue: value,
              ),
            );
            if (id == 'appearance' || id == 'playback') {
              requiresRestart = true;
            }
          }
        case BackupSource.blacklist:
          final mids = _intList(payload, 'mids');
          if (mids == null) {
            skips.add(RestoreSkip(category: id, key: '', reason: '名单结构不合法'));
            continue;
          }
          final current = readBlacklist().toSet();
          if (mergeLists) {
            final additions = mids.where((m) => !current.contains(m)).toList();
            if (additions.isNotEmpty) {
              changes.add(
                RestoreChange(
                  category: id,
                  key: 'mids',
                  kind: RestoreChangeKind.addToList,
                  oldValue: current.toList()..sort(),
                  newValue: additions..sort(),
                ),
              );
            }
          } else if (!_sameIntSet(current, mids)) {
            changes.add(
              RestoreChange(
                category: id,
                key: 'mids',
                kind: RestoreChangeKind.replaceList,
                oldValue: current.toList()..sort(),
                newValue: mids.toList()..sort(),
              ),
            );
          }
        case BackupSource.aiExplicit:
          final data = _asMap(payload);
          if (data == null) {
            skips.add(RestoreSkip(category: id, key: '', reason: 'AI 偏好结构不合法'));
            continue;
          }
          final restored = AiRecommendSettings.fromMap(
            data,
          ).copyWith(enabled: false);
          final current = readAiSettings();
          if (!_jsonEquals(current.toMap(), restored.toMap())) {
            changes.add(
              RestoreChange(
                category: id,
                key: 'aiRecommendSettings',
                kind: RestoreChangeKind.replaceAiSettings,
                oldValue: current.toMap(),
                newValue: restored.toMap(),
              ),
            );
            requiresRestart = true;
          }
          notes.add('AI 推荐筛选保持关闭，确认模型地址后再手动开启。');
        case BackupSource.aiProfile:
          final data = _asMap(payload);
          final scope = data?['accountScope'];
          if (scope is! String || scope != targetScope) {
            skips.add(
              RestoreSkip(
                category: id,
                key: 'accountScope',
                reason: '画像属于其他账号作用域，已跳过',
              ),
            );
            continue;
          }
          final rawProfile = data?['profile'];
          if (rawProfile is! Map) {
            skips.add(
              RestoreSkip(category: id, key: '', reason: '没有可恢复的画像'),
            );
            continue;
          }
          final profile = InterestProfile.fromJson(
            rawProfile,
            accountScope: targetScope,
          );
          final current = await readCurrentProfile();
          if (current != null &&
              _jsonEquals(current.toJson(), profile.toJson())) {
            continue;
          }
          changes.add(
            RestoreChange(
              category: id,
              key: 'profile',
              kind: RestoreChangeKind.replaceProfile,
              oldValue: current?.toJson(),
              newValue: profile.toJson(),
            ),
          );
        case BackupSource.searchHistory:
          final items = _stringList(payload, 'items');
          if (items == null) {
            skips.add(RestoreSkip(category: id, key: '', reason: '搜索历史结构不合法'));
            continue;
          }
          final current = readSearchHistory();
          if (mergeLists) {
            final additions = <String>[];
            for (final item in items) {
              if (!current.contains(item) && !additions.contains(item)) {
                additions.add(item);
              }
            }
            if (additions.isNotEmpty) {
              changes.add(
                RestoreChange(
                  category: id,
                  key: 'items',
                  kind: RestoreChangeKind.addToList,
                  oldValue: current,
                  newValue: additions,
                ),
              );
            }
          } else if (!_sameStrings(current, items)) {
            changes.add(
              RestoreChange(
                category: id,
                key: 'items',
                kind: RestoreChangeKind.replaceList,
                oldValue: current,
                newValue: items,
              ),
            );
          }
        case BackupSource.localReplies:
          final items = _stringList(payload, 'items');
          if (items == null) {
            skips.add(RestoreSkip(category: id, key: '', reason: '评论结构不合法'));
            continue;
          }
          final current = readReplies();
          if (!_sameStrings(current, items)) {
            changes.add(
              RestoreChange(
                category: id,
                key: 'items',
                kind: RestoreChangeKind.replaceList,
                oldValue: current,
                newValue: items,
              ),
            );
          }
        case BackupSource.watchProgress:
          final data = _asMap(payload);
          final raw = data?['progress'];
          if (raw is! Map) {
            skips.add(RestoreSkip(category: id, key: '', reason: '播放进度结构不合法'));
            continue;
          }
          final incoming = <String, int>{};
          for (final entry in raw.entries) {
            if (entry.key is String && entry.value is int) {
              incoming[entry.key as String] = entry.value as int;
            } else {
              skips.add(
                RestoreSkip(
                  category: id,
                  key: entry.key.toString(),
                  reason: '进度值不合法，已跳过',
                ),
              );
            }
          }
          final current = readWatchProgress();
          final additions = <String, int>{};
          incoming.forEach((key, value) {
            if (current[key] != value) additions[key] = value;
          });
          if (additions.isNotEmpty) {
            changes.add(
              RestoreChange(
                category: id,
                key: 'progress',
                kind: RestoreChangeKind.mergeProgress,
                oldValue: current,
                newValue: additions,
              ),
            );
          }
        case BackupSource.font:
          final font = archive.font;
          if (font == null) {
            skips.add(RestoreSkip(category: id, key: '', reason: '快照未包含字体文件'));
            continue;
          }
          final data = _asMap(payload);
          final family = data?['family'];
          changes.add(
            RestoreChange(
              category: id,
              key: 'font.bin',
              kind: RestoreChangeKind.installFont,
              oldValue: currentFontFamily,
              newValue: family is String ? family : '',
            ),
          );
      }
    }

    final selected = [
      for (final entry in archive.categories.entries)
        if (selection.includes(entry.key)) entry.key,
    ]..sort();
    return RestorePlan(
      manifest: archive.manifest,
      changes: changes,
      skips: skips,
      selectedCategories: selected,
      requiresRestart: requiresRestart,
      notes: notes,
      fontFamily: archive.font == null
          ? null
          : (archive.categories['font'] is Map
                ? (archive.categories['font'] as Map)['family'] as String?
                : null),
    );
  }

  static Map<String, Object?>? _asMap(Object? raw) {
    if (raw is! Map) return null;
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }

  static List<int>? _intList(Object? payload, String key) {
    final map = _asMap(payload);
    final raw = map?[key];
    if (raw is! List) return null;
    if (raw.any((e) => e is! int)) return null;
    return raw.cast<int>();
  }

  static List<String>? _stringList(Object? payload, String key) {
    final map = _asMap(payload);
    final raw = map?[key];
    if (raw is! List) return null;
    if (raw.any((e) => e is! String)) return null;
    return raw.cast<String>();
  }

  static bool _sameIntSet(Set<int> current, List<int> incoming) =>
      current.length == incoming.toSet().length &&
      current.containsAll(incoming);

  static bool _sameStrings(List<String> a, List<String> b) =>
      a.length == b.length && a.join('\u0000') == b.join('\u0000');

  static bool _jsonEquals(Object? a, Object? b) =>
      jsonEncode(_normalize(a)) == jsonEncode(_normalize(b));

  static Object? _normalize(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((e) => e.toString()).toList()..sort();
      return {
        for (final key in keys) key: _normalize(value[key]),
      };
    }
    if (value is List) return value.map(_normalize).toList();
    if (value is num) return value;
    return value;
  }
}
