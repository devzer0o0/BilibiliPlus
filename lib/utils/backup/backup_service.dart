// ignore_for_file: prefer_interpolation_to_compose_strings, unnecessary_lambdas
import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/models/backup/backup_config.dart';
import 'package:PiliPlus/models/backup/backup_record.dart';
import 'package:PiliPlus/models/backup/backup_snapshot.dart';
import 'package:PiliPlus/pages/rcmd/controller.dart';
import 'package:PiliPlus/utils/ai_recommend/ai_recommendation_service.dart';
import 'package:PiliPlus/utils/ai_recommend/interest_profile_repository.dart';
import 'package:PiliPlus/utils/backup/backup_codec.dart';
import 'package:PiliPlus/utils/backup/backup_crypto.dart';
import 'package:PiliPlus/utils/backup/backup_history_repository.dart';
import 'package:PiliPlus/utils/backup/backup_key_service.dart';
import 'package:PiliPlus/utils/backup/backup_snapshot_builder.dart';
import 'package:PiliPlus/utils/backup/hive_restore_writer.dart';
import 'package:PiliPlus/utils/backup/restore_coordinator.dart';
import 'package:PiliPlus/utils/backup/restore_planner.dart';
import 'package:PiliPlus/utils/backup/s3_object_store.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/font_utils.dart';
import 'package:PiliPlus/utils/recommend_filter.dart';
import 'package:PiliPlus/utils/security/secret_store.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

enum BackupTaskStatus {
  idle,
  preparing,
  encrypting,
  uploading,
  verifying,
  done,
  failed,
  skipped,
  needsAttention,
}

class BackupTaskState {
  const BackupTaskState({
    this.status = BackupTaskStatus.idle,
    this.message = '',
    this.record,
  });

  final BackupTaskStatus status;
  final String message;
  final BackupSnapshotRecord? record;

  bool get isRunning =>
      status == BackupTaskStatus.preparing ||
      status == BackupTaskStatus.encrypting ||
      status == BackupTaskStatus.uploading ||
      status == BackupTaskStatus.verifying;
}

class RestorePreview {
  const RestorePreview({required this.plan, this.font});

  final RestorePlan plan;
  final Uint8List? font;
}

class BackupService {
  BackupService._();

  static final BackupService instance = BackupService._();

  late final SecretStore secrets = FlutterSecretStore();
  late final BackupKeyService keys = BackupKeyService(secrets);
  late final BackupHistoryRepository repository = BackupHistoryRepository(
    HiveBackupMetadataStore(GStorage.backup),
  );
  final ValueNotifier<BackupTaskState> state = ValueNotifier(
    const BackupTaskState(),
  );
  bool _running = false;
  bool _restoring = false;

  bool get isRunning => _running;
  bool get isRestoring => _restoring;

  void markAttention(String message) {
    if (state.value.isRunning) return;
    state.value = BackupTaskState(
      status: BackupTaskStatus.needsAttention,
      message: message,
    );
  }

  /// Must be called early in startup, before controllers read restored
  /// settings. A committed journal is cleaned; an interrupted one is rolled
  /// back.
  Future<RecoveryResult> recoverPendingRestore() {
    final coordinator = RestoreCoordinator(
      repository: repository,
      writer: HiveRestoreWriter(
        accountScope: AiRecommendationService.instance.recommendScope,
      ),
    );
    return coordinator.recoverIfNeeded();
  }

  S3BackupConfig get config => repository.loadConfig();

  Future<void> saveConfig(S3BackupConfig value) => repository.saveConfig(value);

  Future<void> saveCredentials({
    required String accessKeyId,
    required String secretAccessKey,
    String? sessionToken,
  }) async {
    await secrets.write(SecretKeys.s3AccessKeyId, accessKeyId.trim());
    await secrets.write(SecretKeys.s3SecretAccessKey, secretAccessKey.trim());
    if (sessionToken == null || sessionToken.trim().isEmpty) {
      await secrets.delete(SecretKeys.s3SessionToken);
    } else {
      await secrets.write(SecretKeys.s3SessionToken, sessionToken.trim());
    }
  }

  Future<S3Credentials?> credentials() async {
    final id = await secrets.read(SecretKeys.s3AccessKeyId);
    final secret = await secrets.read(SecretKeys.s3SecretAccessKey);
    final token = await secrets.read(SecretKeys.s3SessionToken);
    if (id == null || secret == null || id.isEmpty || secret.isEmpty) {
      return null;
    }
    return S3Credentials(
      accessKeyId: id,
      secretAccessKey: secret,
      sessionToken: token,
    );
  }

  Future<bool> hasCredentials() async => (await credentials()) != null;

  Future<S3ObjectStore> _store() async {
    final creds = await credentials();
    if (creds == null) {
      throw const S3Exception(S3Failure.auth, '未保存 S3 Access Key / Secret');
    }
    return S3ObjectStore(config: config, credentials: creds);
  }

  Future<S3ConnectionReport> testConnection() async =>
      (await _store()).connectionTest();

  Future<RecoveryKeyInfo> ensureRecoveryKey() => keys.ensureKey();

  Future<String?> recoveryKeyId() => keys.keyId();

  Future<RecoveryKeyInfo> importRecoveryCode(String code) =>
      keys.importCode(code);

  BackupSnapshotBuilder _builder() => BackupSnapshotBuilder(
    readSetting: (key) => GStorage.setting.get(key),
    readVideoSetting: (key) => GStorage.video.get(key),
    readBlacklist: () => Pref.blackMids.toList(),
    readSearchHistory: () {
      final raw = GStorage.historyWord.get('cacheList');
      return raw is List ? raw.whereType<String>().toList() : const [];
    },
    readReplies: () {
      final box = GStorage.reply;
      if (box == null) return const [];
      return box.values.map((e) => base64Encode(e)).toList();
    },
    readWatchProgress: () => {
      for (final entry in GStorage.watchProgress.toMap().entries)
        entry.key.toString(): entry.value,
    },
    readFont: () {
      try {
        return FontUtils.fontFile.existsSync()
            ? FontUtils.fontFile.readAsBytesSync()
            : null;
      } catch (_) {
        return null;
      }
    },
    readAiSettings: () => Pref.aiRecommendSettings,
    readAiProfile: () => HiveInterestProfileStore(
      GStorage.aiProfile,
    ).read(AiRecommendationService.instance.recommendScope),
    recommendScope: AiRecommendationService.instance.recommendScope,
    platform: DeviceUtils.platformName,
    appName: 'Bilibili+',
    appVersion: BuildConfig.versionName,
    appBuild: BuildConfig.versionCode.toString(),
  );

  Future<BackupDraft> buildDraft({BackupSelection? selection}) async {
    final cfg = config;
    final draft = await _builder().build(
      selection: selection ?? cfg.selection,
      snapshotId: randomId(8),
      deviceId: repository.deviceId,
      backupSetId: repository.backupSetId,
    );
    return draft;
  }

  Future<BackupTaskState> backupNow({
    bool auto = false,
    BackupSelection? selection,
  }) async {
    if (_running) return state.value;
    _running = true;
    _set(BackupTaskStatus.preparing, auto ? '自动备份准备中' : '正在准备备份');
    try {
      final cfg = config;
      final invalid = cfg.validationError();
      if (invalid != null) {
        throw BackupFormatException(invalid);
      }
      final creds = await credentials();
      if (creds == null) {
        throw const S3Exception(S3Failure.auth, '未保存 S3 凭据');
      }
      final key = await keys.readKey();
      if (key == null) {
        throw const BackupCryptoException('尚未生成恢复密钥');
      }
      final draft = await buildDraft(selection: selection);
      if (auto && repository.baselineHash == draft.contentFingerprint) {
        _set(BackupTaskStatus.skipped, '内容未变化，跳过自动备份');
        return state.value;
      }
      _set(BackupTaskStatus.encrypting, '正在压缩并加密');
      final zip = BackupCodec.encode(
        manifest: draft.manifest,
        categories: draft.categories,
        font: draft.font,
      );
      final encrypted = await BackupCrypto.encrypt(zip, key);
      final hash = sha256.convert(encrypted).toString();
      // Prove the file can be decrypted and decoded before it leaves the
      // device. This catches a wrong key or an invalid archive early.
      final check = BackupCodec.decode(
        await BackupCrypto.decrypt(encrypted, key),
      );
      if (check.manifest.snapshotId != draft.manifest.snapshotId) {
        throw const BackupFormatException('本地自检失败');
      }

      final createdAt = DateTime.now().toUtc();
      final keyName =
          S3ObjectStore(
            config: cfg,
            credentials: creds,
          ).keyForSnapshot(
            backupSetId: repository.backupSetId,
            deviceId: repository.deviceId,
            snapshotId: draft.manifest.snapshotId,
            createdAt: createdAt,
          );
      _set(BackupTaskStatus.uploading, '正在上传');
      final store = await _store();
      await store.uploadVerified(
        key: keyName,
        bytes: encrypted,
        sha256Hex: hash,
        metadata: {
          'snapshot': draft.manifest.snapshotId,
          'content': draft.contentFingerprint,
        },
      );
      _set(BackupTaskStatus.verifying, '正在回读校验');
      final record = BackupSnapshotRecord(
        key: keyName,
        size: encrypted.length,
        createdAt: createdAt.toIso8601String(),
        lastModified: createdAt.toIso8601String(),
        deviceId: repository.deviceId,
        backupSetId: repository.backupSetId,
        snapshotId: draft.manifest.snapshotId,
        contentHash: draft.contentFingerprint,
        keyId: BackupCrypto.keyId(key),
        categories: draft.manifest.categories,
        auto: auto,
        verified: true,
      );
      await repository.addRecord(record);
      await repository.markAutoBackup(createdAt, draft.contentFingerprint);
      _set(BackupTaskStatus.done, '备份完成并已回读校验', record);
      return state.value;
    } on S3Exception catch (e) {
      _set(BackupTaskStatus.failed, _s3Message(e));
    } on BackupCryptoException catch (e) {
      _set(BackupTaskStatus.failed, e.message);
    } on BackupFormatException catch (e) {
      _set(BackupTaskStatus.failed, e.message);
    } on SecretStoreException catch (e) {
      _set(BackupTaskStatus.failed, e.message);
    } on Object catch (_) {
      _set(BackupTaskStatus.failed, '备份失败');
    } finally {
      _running = false;
    }
    return state.value;
  }

  Future<List<BackupSnapshotRecord>> listSnapshots() async {
    final store = await _store();
    final prefix = config.normalizedPrefix + '/v1/';
    final objects = await store.listAll(prefix: prefix);
    final local = {
      for (final record in repository.records()) record.key: record,
    };
    final result = <BackupSnapshotRecord>[];
    for (final object in objects) {
      final record = _recordFromObject(object, local[object.key]);
      if (record != null) result.add(record);
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  Future<BackupArchive> inspectSnapshot(String key) async {
    final store = await _store();
    final bytes = await store.getObject(key);
    final keyBytes = await keys.readKey();
    if (keyBytes == null) {
      throw const BackupCryptoException('本机没有恢复密钥');
    }
    return BackupCodec.decode(await BackupCrypto.decrypt(bytes, keyBytes));
  }

  Future<RestorePreview> preview(
    String key, {
    BackupSelection? selection,
    bool mergeLists = false,
  }) async {
    final bytes = await (await _store()).getObject(key);
    final keyBytes = await keys.readKey();
    if (keyBytes == null) {
      throw const BackupCryptoException('本机没有恢复密钥');
    }
    final archive = BackupCodec.decode(
      await BackupCrypto.decrypt(bytes, keyBytes),
    );
    final planner = RestorePlanner(
      readSetting: (name) => GStorage.setting.get(name),
      readBlacklist: () => Pref.blackMids.toList(),
      readSearchHistory: () {
        final raw = GStorage.historyWord.get('cacheList');
        return raw is List ? raw.whereType<String>().toList() : const [];
      },
      readReplies: () {
        final box = GStorage.reply;
        if (box == null) return const [];
        return box.values.map((e) => base64Encode(e)).toList();
      },
      readWatchProgress: () => {
        for (final entry in GStorage.watchProgress.toMap().entries)
          entry.key.toString(): entry.value,
      },
      readAiSettings: () => Pref.aiRecommendSettings,
      readCurrentProfile: () => HiveInterestProfileStore(
        GStorage.aiProfile,
      ).read(AiRecommendationService.instance.recommendScope),
      targetPlatform: DeviceUtils.platformName,
      targetScope: AiRecommendationService.instance.recommendScope,
      currentFontFamily: GStorage.setting.get(SettingBoxKey.appFont) is String
          ? GStorage.setting.get(SettingBoxKey.appFont) as String
          : null,
    );
    final plan = await planner.plan(
      archive,
      selection: selection ?? BackupSelection(archive.categories.keys.toSet()),
      mergeLists: mergeLists,
    );
    return RestorePreview(plan: plan, font: archive.font);
  }

  Future<void> applyRestore(RestorePreview preview) async {
    if (_restoring) return;
    _restoring = true;
    final writer = HiveRestoreWriter(
      accountScope: AiRecommendationService.instance.recommendScope,
    );
    final coordinator = RestoreCoordinator(
      repository: repository,
      writer: writer,
      onApplied: (plan) async {
        RecommendFilter.reload();
        if (plan.changes.any((c) => c.category == 'aiExplicit')) {
          try {
            await AiRecommendationService.instance.secrets.delete(
              SecretKeys.aiApiKey,
            );
          } catch (_) {}
        }
        if (Get.isRegistered<RcmdController>()) {
          await Get.find<RcmdController>().onRefresh();
        }
        try {
          final draft = await buildDraft();
          await repository.markAutoBackup(
            DateTime.now().toUtc(),
            draft.contentFingerprint,
          );
        } catch (_) {}
      },
    );
    try {
      await coordinator.apply(preview.plan, fontBytes: preview.font);
    } finally {
      _restoring = false;
    }
  }

  Future<void> deleteSnapshot(BackupSnapshotRecord record) async {
    final store = await _store();
    await store.deleteObject(record.key);
    await repository.deleteRecord(record.key);
  }

  /// Deletes only automatic snapshots that belong to this device and backup set.
  Future<int> cleanupAutoSnapshots() async {
    final cfg = config;
    if (cfg.retainAutoSnapshots < 1) return 0;
    final records =
        repository
            .records()
            .where(
              (r) =>
                  r.auto &&
                  r.deviceId == repository.deviceId &&
                  r.backupSetId == repository.backupSetId &&
                  r.key.startsWith(
                    cfg.normalizedPrefix +
                        '/v1/' +
                        repository.backupSetId +
                        '/' +
                        repository.deviceId +
                        '/',
                  ),
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    var deleted = 0;
    final store = await _store();
    for (final record in records.skip(cfg.retainAutoSnapshots)) {
      try {
        await store.deleteObject(record.key);
        await repository.deleteRecord(record.key);
        deleted++;
      } on S3Exception {
        break;
      }
    }
    return deleted;
  }

  Future<List<String>> discoverBackupSets() async {
    final store = await _store();
    final prefix = config.normalizedPrefix + '/v1/';
    final objects = await store.listAll(prefix: prefix);
    final sets = <String>{};
    for (final object in objects) {
      final rest = object.key.substring(prefix.length);
      final parts = rest.split('/');
      if (parts.length >= 2 && parts.first.isNotEmpty) sets.add(parts.first);
    }
    return sets.toList()..sort();
  }

  Future<void> useBackupSet(String id) => repository.useBackupSet(id);

  static BackupSnapshotRecord? _recordFromObject(
    S3ObjectInfo object,
    BackupSnapshotRecord? local,
  ) {
    if (!object.key.endsWith('.ppbackup')) return null;
    final rest = object.key.split('/');
    if (rest.length < 3) return null;
    final file = rest.last;
    if (!file.endsWith('.ppbackup') || file.length < 12) return null;
    final dash = file.lastIndexOf('-');
    if (dash < 0 || dash + 1 >= file.length - '.ppbackup'.length) {
      return null;
    }
    final snapshotId = file.substring(
      dash + 1,
      file.length - '.ppbackup'.length,
    );
    final deviceId = rest[rest.length - 2];
    final backupSetId = rest[rest.length - 3];
    final timestamp =
        object.lastModified?.toIso8601String() ??
        local?.createdAt ??
        DateTime.now().toUtc().toIso8601String();
    return BackupSnapshotRecord(
      key: object.key,
      size: object.size,
      createdAt: local?.createdAt ?? timestamp,
      lastModified: object.lastModified?.toIso8601String(),
      deviceId: local?.deviceId ?? deviceId,
      backupSetId: local?.backupSetId ?? backupSetId,
      snapshotId: local?.snapshotId ?? snapshotId,
      contentHash: local?.contentHash ?? '',
      keyId: local?.keyId ?? '',
      categories: local?.categories ?? const [],
      auto: local?.auto ?? false,
      verified: local?.verified ?? false,
    );
  }

  void _set(
    BackupTaskStatus status,
    String message, [
    BackupSnapshotRecord? record,
  ]) {
    state.value = BackupTaskState(
      status: status,
      message: message,
      record: record,
    );
  }

  static String _s3Message(S3Exception e) => switch (e.failure) {
    S3Failure.auth => 'S3 鉴权失败，请检查 Access Key',
    S3Failure.accessDenied => '没有执行该操作的权限',
    S3Failure.notFound => 'Bucket 或对象不存在',
    S3Failure.signature => '签名失败，请检查 Endpoint、Region 和寻址模式',
    S3Failure.region => 'Region 与 Endpoint 不匹配',
    S3Failure.clockSkew => '设备时间偏差过大，请校准后重试',
    S3Failure.preconditionFailed => '同名快照已存在，未覆盖',
    S3Failure.conflict => '同名对象内容不同，未覆盖',
    S3Failure.network => '网络不可用',
    S3Failure.tls => 'TLS 证书校验失败',
    S3Failure.timeout => '请求超时',
    S3Failure.server => 'S3 服务暂时不可用',
    S3Failure.rateLimited => 'S3 服务限流',
    S3Failure.invalidResponse => 'S3 响应无法识别',
    S3Failure.cancelled => '请求已取消',
  };
}
