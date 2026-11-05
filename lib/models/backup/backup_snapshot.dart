import 'dart:convert';
import 'dart:typed_data';

class BackupFileInfo {
  const BackupFileInfo({
    required this.name,
    required this.bytes,
    required this.sha256,
  });

  final String name;
  final int bytes;
  final String sha256;

  Map<String, dynamic> toJson() => {
    'name': name,
    'bytes': bytes,
    'sha256': sha256,
  };

  static BackupFileInfo? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    final bytes = raw['bytes'];
    final hash = raw['sha256'];
    if (name is! String || bytes is! int || hash is! String) return null;
    return BackupFileInfo(name: name, bytes: bytes, sha256: hash);
  }
}

class BackupManifest {
  const BackupManifest({
    this.formatVersion = currentFormatVersion,
    this.schemaVersions = const {},
    this.appName = 'Bilibili+',
    this.appVersion = '',
    this.appBuild = '',
    this.platform = '',
    required this.createdAt,
    required this.snapshotId,
    required this.deviceId,
    required this.backupSetId,
    this.categories = const [],
    this.files = const [],
    this.contentHash = '',
    this.warnings = const [],
    this.profileScope,
  });

  static const int currentFormatVersion = 1;

  final int formatVersion;
  final Map<String, int> schemaVersions;
  final String appName;
  final String appVersion;
  final String appBuild;
  final String platform;
  final String createdAt;
  final String snapshotId;
  final String deviceId;
  final String backupSetId;
  final List<String> categories;
  final List<BackupFileInfo> files;
  final String contentHash;
  final List<String> warnings;

  /// Only present when the AI profile category is included. Used by the
  /// restore planner to refuse mixing profiles between accounts.
  final String? profileScope;

  Map<String, dynamic> toJson() => {
    'formatVersion': formatVersion,
    'schemaVersions': schemaVersions,
    'appName': appName,
    'appVersion': appVersion,
    'appBuild': appBuild,
    'platform': platform,
    'createdAt': createdAt,
    'snapshotId': snapshotId,
    'deviceId': deviceId,
    'backupSetId': backupSetId,
    'categories': categories,
    'files': files.map((f) => f.toJson()).toList(),
    'contentHash': contentHash,
    'warnings': warnings,
    if (profileScope != null) 'profileScope': profileScope,
  };

  String toJsonString() => jsonEncode(toJson());

  BackupManifest copyWith({
    List<BackupFileInfo>? files,
    String? contentHash,
    List<String>? warnings,
  }) => BackupManifest(
    formatVersion: formatVersion,
    schemaVersions: schemaVersions,
    appName: appName,
    appVersion: appVersion,
    appBuild: appBuild,
    platform: platform,
    createdAt: createdAt,
    snapshotId: snapshotId,
    deviceId: deviceId,
    backupSetId: backupSetId,
    categories: categories,
    files: files ?? this.files,
    contentHash: contentHash ?? this.contentHash,
    warnings: warnings ?? this.warnings,
    profileScope: profileScope,
  );

  static BackupManifest? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final createdAt = raw['createdAt'];
    final snapshotId = raw['snapshotId'];
    final deviceId = raw['deviceId'];
    final backupSetId = raw['backupSetId'];
    if (createdAt is! String ||
        snapshotId is! String ||
        deviceId is! String ||
        backupSetId is! String) {
      return null;
    }
    final schemas = <String, int>{};
    if (raw['schemaVersions'] is Map) {
      (raw['schemaVersions'] as Map).forEach((key, value) {
        if (key is String && value is int) schemas[key] = value;
      });
    }
    final files = <BackupFileInfo>[];
    if (raw['files'] is List) {
      for (final item in raw['files'] as List) {
        final file = BackupFileInfo.fromJson(item);
        if (file != null) files.add(file);
      }
    }
    return BackupManifest(
      formatVersion: raw['formatVersion'] is int
          ? raw['formatVersion'] as int
          : 0,
      schemaVersions: schemas,
      appName: raw['appName'] is String
          ? raw['appName'] as String
          : 'Bilibili+',
      appVersion: raw['appVersion'] is String
          ? raw['appVersion'] as String
          : '',
      appBuild: raw['appBuild'] is String ? raw['appBuild'] as String : '',
      platform: raw['platform'] is String ? raw['platform'] as String : '',
      createdAt: createdAt,
      snapshotId: snapshotId,
      deviceId: deviceId,
      backupSetId: backupSetId,
      categories: raw['categories'] is List
          ? (raw['categories'] as List).whereType<String>().toList()
          : const [],
      files: files,
      contentHash: raw['contentHash'] is String
          ? raw['contentHash'] as String
          : '',
      warnings: raw['warnings'] is List
          ? (raw['warnings'] as List).whereType<String>().toList()
          : const [],
      profileScope: raw['profileScope'] is String
          ? raw['profileScope'] as String
          : null,
    );
  }
}

class BackupArchive {
  const BackupArchive({
    required this.manifest,
    required this.categories,
    this.font,
  });

  final BackupManifest manifest;

  /// Category id -> category payload. Shapes are defined by the registry:
  /// settings categories are key->value maps, lists are arrays, profile is an
  /// object. Kept as Object? so a newer scalar/list shape can be rejected by
  /// the planner rather than crashing the codec.
  final Map<String, Object?> categories;

  final Uint8List? font;
}

class BackupFormatException implements Exception {
  const BackupFormatException(this.message);

  final String message;

  @override
  String toString() => 'BackupFormatException($message)';
}
