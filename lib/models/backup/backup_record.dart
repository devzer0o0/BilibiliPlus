import 'dart:math' as math;

class BackupSnapshotRecord {
  const BackupSnapshotRecord({
    required this.key,
    required this.size,
    required this.createdAt,
    required this.deviceId,
    required this.backupSetId,
    required this.snapshotId,
    this.lastModified,
    this.contentHash = '',
    this.keyId = '',
    this.categories = const [],
    this.auto = false,
    this.verified = false,
  });

  final String key;
  final int size;
  final String createdAt;
  final String? lastModified;
  final String deviceId;
  final String backupSetId;
  final String snapshotId;
  final String contentHash;
  final String keyId;
  final List<String> categories;
  final bool auto;
  final bool verified;

  DateTime? get createdDateTime => DateTime.tryParse(createdAt);

  BackupSnapshotRecord copyWith({bool? verified, int? size}) =>
      BackupSnapshotRecord(
        key: key,
        size: size ?? this.size,
        createdAt: createdAt,
        lastModified: lastModified,
        deviceId: deviceId,
        backupSetId: backupSetId,
        snapshotId: snapshotId,
        contentHash: contentHash,
        keyId: keyId,
        categories: categories,
        auto: auto,
        verified: verified ?? this.verified,
      );

  Map<String, dynamic> toMap() => {
    'key': key,
    'size': size,
    'createdAt': createdAt,
    'lastModified': lastModified,
    'deviceId': deviceId,
    'backupSetId': backupSetId,
    'snapshotId': snapshotId,
    'contentHash': contentHash,
    'keyId': keyId,
    'categories': categories,
    'auto': auto,
    'verified': verified,
  };

  static BackupSnapshotRecord? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['key'];
    final createdAt = raw['createdAt'];
    final deviceId = raw['deviceId'];
    final backupSetId = raw['backupSetId'];
    final snapshotId = raw['snapshotId'];
    if (key is! String ||
        createdAt is! String ||
        deviceId is! String ||
        backupSetId is! String ||
        snapshotId is! String) {
      return null;
    }
    return BackupSnapshotRecord(
      key: key,
      size: raw['size'] is int ? raw['size'] as int : 0,
      createdAt: createdAt,
      lastModified: raw['lastModified'] is String
          ? raw['lastModified'] as String
          : null,
      deviceId: deviceId,
      backupSetId: backupSetId,
      snapshotId: snapshotId,
      contentHash: raw['contentHash'] is String
          ? raw['contentHash'] as String
          : '',
      keyId: raw['keyId'] is String ? raw['keyId'] as String : '',
      categories: raw['categories'] is List
          ? (raw['categories'] as List).whereType<String>().toList()
          : const [],
      auto: raw['auto'] is bool ? raw['auto'] as bool : false,
      verified: raw['verified'] is bool ? raw['verified'] as bool : false,
    );
  }
}

String randomId([int bytes = 12]) {
  final random = math.Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < bytes; i++) {
    buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
