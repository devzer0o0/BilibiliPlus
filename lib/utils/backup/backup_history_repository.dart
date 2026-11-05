import 'package:PiliPlus/models/backup/backup_config.dart';
import 'package:PiliPlus/models/backup/backup_record.dart';

abstract interface class BackupMetadataStore {
  Object? read(String key);
  Future<void> write(String key, Object? value);
  Future<void> delete(String key);
}

class HiveBackupMetadataStore implements BackupMetadataStore {
  HiveBackupMetadataStore(this.box);

  final dynamic box;

  @override
  Object? read(String key) => box.get(key);

  @override
  Future<void> write(String key, Object? value) => box.put(key, value);

  @override
  Future<void> delete(String key) => box.delete(key);
}

class MemoryBackupMetadataStore implements BackupMetadataStore {
  final Map<String, Object?> values = {};

  @override
  Object? read(String key) => values[key];

  @override
  Future<void> write(String key, Object? value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

/// Durable, non-secret backup metadata. Deliberately does not contain AWS
/// credentials or the recovery key.
class BackupHistoryRepository {
  BackupHistoryRepository(this.store);

  final BackupMetadataStore store;

  static const String configKey = 'config.s3.v1';
  static const String historyKey = 'history.v1';
  static const String deviceKey = 'device.id';
  static const String setKey = 'set.id';
  static const String lastAutoKey = 'auto.lastAt';
  static const String baselineHashKey = 'auto.baselineHash';
  static const String journalKey = 'restore.journal.v1';

  S3BackupConfig loadConfig() => S3BackupConfig.fromMap(store.read(configKey));

  Future<void> saveConfig(S3BackupConfig config) =>
      store.write(configKey, config.toMap());

  String get deviceId {
    final value = store.read(deviceKey);
    if (value is String && value.isNotEmpty) return value;
    final created = randomId(8);
    store.write(deviceKey, created);
    return created;
  }

  String get backupSetId {
    final value = store.read(setKey);
    if (value is String && value.isNotEmpty) return value;
    final created = randomId(6);
    store.write(setKey, created);
    return created;
  }

  Future<void> useBackupSet(String id) async {
    if (id.trim().isEmpty) return;
    await store.write(setKey, id.trim());
  }

  List<BackupSnapshotRecord> records() {
    final raw = store.read(historyKey);
    if (raw is! List) return const [];
    final result = <BackupSnapshotRecord>[];
    for (final item in raw) {
      final record = BackupSnapshotRecord.fromMap(item);
      if (record != null) result.add(record);
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  Future<void> addRecord(BackupSnapshotRecord record) async {
    final all = [
      record,
      ...records().where((r) => r.key != record.key),
    ];
    if (all.length > 500) all.removeRange(500, all.length);
    await store.write(historyKey, all.map((r) => r.toMap()).toList());
  }

  Future<void> deleteRecord(String key) async {
    final all = records().where((r) => r.key != key).toList();
    await store.write(historyKey, all.map((r) => r.toMap()).toList());
  }

  DateTime? get lastAutoAt {
    final raw = store.read(lastAutoKey);
    return raw is String ? DateTime.tryParse(raw) : null;
  }

  Future<void> markAutoBackup(DateTime at, String contentHash) async {
    await store.write(lastAutoKey, at.toUtc().toIso8601String());
    await store.write(baselineHashKey, contentHash);
  }

  String? get baselineHash {
    final raw = store.read(baselineHashKey);
    return raw is String ? raw : null;
  }

  Map<String, dynamic>? get journal {
    final raw = store.read(journalKey);
    return raw is Map ? Map<String, dynamic>.from(raw) : null;
  }

  Future<void> writeJournal(Map<String, dynamic> journal) =>
      store.write(journalKey, journal);

  Future<void> clearJournal() => store.delete(journalKey);
}
