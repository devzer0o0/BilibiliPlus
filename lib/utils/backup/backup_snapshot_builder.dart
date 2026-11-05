// ignore_for_file: prefer_interpolation_to_compose_strings, unnecessary_lambdas
import 'dart:convert';
import 'dart:typed_data';

import 'package:PiliPlus/models/ai_recommend/ai_recommend_settings.dart';
import 'package:PiliPlus/models/ai_recommend/interest_profile.dart';
import 'package:PiliPlus/models/backup/backup_config.dart';
import 'package:PiliPlus/models/backup/backup_snapshot.dart';
import 'package:PiliPlus/utils/backup/backup_codec.dart';
import 'package:PiliPlus/utils/backup/backup_registry.dart';
import 'package:crypto/crypto.dart';

class BackupDraft {
  const BackupDraft({
    required this.manifest,
    required this.categories,
    this.font,
    this.warnings = const [],
  });

  final BackupManifest manifest;
  final Map<String, Object?> categories;
  final Uint8List? font;
  final List<String> warnings;

  /// Stable content identity used to avoid re-uploading unchanged settings.
  /// Export time, snapshot id and device id are deliberately excluded.
  String get contentFingerprint {
    final fontHash = font == null ? '' : sha256.convert(font!).toString();
    return sha256
        .convert(
          utf8.encode(
            BackupCodec.canonicalJson(categories) + '|' + fontHash,
          ),
        )
        .toString();
  }
}

typedef SettingReader = Object? Function(String key);
typedef BytesReader = Uint8List? Function();

class BackupSnapshotBuilder {
  BackupSnapshotBuilder({
    required this.readSetting,
    required this.readVideoSetting,
    required this.readBlacklist,
    required this.readSearchHistory,
    required this.readReplies,
    required this.readWatchProgress,
    required this.readFont,
    required this.readAiSettings,
    required this.readAiProfile,
    required this.recommendScope,
    required this.platform,
    this.appName = 'Bilibili+',
    this.appVersion = '',
    this.appBuild = '',
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final SettingReader readSetting;
  final SettingReader readVideoSetting;
  final List<int> Function() readBlacklist;
  final List<String> Function() readSearchHistory;
  final List<String> Function() readReplies;
  final Map<String, int> Function() readWatchProgress;
  final BytesReader readFont;
  final AiRecommendSettings Function() readAiSettings;
  final Future<InterestProfile?> Function() readAiProfile;
  final String recommendScope;
  final String platform;
  final String appName;
  final String appVersion;
  final String appBuild;
  final DateTime Function() _clock;

  Future<BackupDraft> build({
    required BackupSelection selection,
    required String snapshotId,
    required String deviceId,
    required String backupSetId,
  }) async {
    final categories = <String, Object?>{};
    final warnings = <String>[];
    Uint8List? font;
    InterestProfile? profile;

    for (final id in selection.ids.toList()..sort()) {
      final spec = BackupRegistry.byId(id);
      if (spec == null) {
        warnings.add('跳过未知分类：' + id);
        continue;
      }
      switch (spec.source) {
        case BackupSource.setting:
        case BackupSource.videoSetting:
          final data = <String, Object?>{};
          for (final key in spec.settingKeys) {
            if (BackupRegistry.isExcludedSettingKey(key)) {
              warnings.add('已排除凭据字段：' + key);
              continue;
            }
            final value = spec.source == BackupSource.videoSetting
                ? readVideoSetting(key)
                : readSetting(key);
            if (value == null) continue;
            if (!BackupRegistry.isSupportedValueType(spec, value)) {
              warnings.add('跳过不支持的类型：' + key);
              continue;
            }
            data[key] = value;
          }
          categories[spec.id] = data;
        case BackupSource.blacklist:
          categories[spec.id] = {
            'mids': (readBlacklist().toList()..sort()),
          };
        case BackupSource.aiExplicit:
          categories[spec.id] = readAiSettings().toMap();
        case BackupSource.aiProfile:
          profile = await readAiProfile();
          categories[spec.id] = {
            'accountScope': recommendScope,
            'profile': profile?.toJson(),
          };
        case BackupSource.searchHistory:
          categories[spec.id] = {'items': readSearchHistory()};
        case BackupSource.localReplies:
          categories[spec.id] = {'items': readReplies()};
        case BackupSource.watchProgress:
          categories[spec.id] = {'progress': readWatchProgress()};
        case BackupSource.font:
          font = readFont();
          categories[spec.id] = {
            'family': readSetting('appFont'),
            'included': font != null,
          };
          if (font == null) warnings.add('未找到可备份的字体文件');
      }
    }

    final manifest = BackupManifest(
      createdAt: _clock().toUtc().toIso8601String(),
      snapshotId: snapshotId,
      deviceId: deviceId,
      backupSetId: backupSetId,
      appName: appName,
      appVersion: appVersion,
      appBuild: appBuild,
      platform: platform,
      categories: categories.keys.toList()..sort(),
      schemaVersions: {
        for (final id in categories.keys) id: BackupRegistry.schemaVersion,
      },
      warnings: warnings,
      profileScope: categories.containsKey('aiProfile') ? recommendScope : null,
    );
    return BackupDraft(
      manifest: manifest,
      categories: categories,
      font: font,
      warnings: warnings,
    );
  }
}
