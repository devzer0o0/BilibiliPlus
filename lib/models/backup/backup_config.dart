import 'dart:convert';

import 'package:PiliPlus/utils/security/private_network.dart';

/// Addressing style for an S3-compatible endpoint.
enum S3AddressingMode {
  virtualHosted('virtual-hosted'),
  pathStyle('path-style');

  const S3AddressingMode(this.id);

  final String id;

  static S3AddressingMode fromId(Object? value) {
    for (final mode in values) {
      if (mode.id == value || mode.name == value) return mode;
    }
    return pathStyle;
  }
}

/// Which categories a backup includes. IDs are stable strings, not enum
/// indexes, so an old archive keeps its meaning after a category is inserted.
class BackupSelection {
  const BackupSelection(this.ids);

  final Set<String> ids;

  static const BackupSelection none = BackupSelection({});

  bool includes(String id) => ids.contains(id);

  BackupSelection toggle(String id, bool selected) {
    final next = {...ids};
    if (selected) {
      next.add(id);
    } else {
      next.remove(id);
    }
    return BackupSelection(next);
  }

  Map<String, dynamic> toMap() => {
    'ids': [...ids]..sort(),
  };

  static BackupSelection fromMap(Object? raw) {
    if (raw is Map && raw['ids'] is List) {
      return BackupSelection(
        (raw['ids'] as List).whereType<String>().toSet(),
      );
    }
    return none;
  }
}

/// Non-secret S3 connection and automation settings.
///
/// Access key ID, secret key and session token are never here; they live in the
/// platform secret store under [SecretKeys]. [toMap] is therefore safe for Hive
/// but still not included in a backup.
class S3BackupConfig {
  const S3BackupConfig({
    this.displayName = '',
    this.endpoint = '',
    this.bucket = '',
    this.region = '',
    this.prefix = 'PiliPlusBackups',
    this.addressing = S3AddressingMode.pathStyle,
    this.allowInsecureHttp = false,
    this.timeoutSeconds = 20,
    this.autoEnabled = false,
    this.autoWifiOnly = true,
    this.autoIntervalHours = 6,
    this.retainAutoSnapshots = 20,
    this.selection = const BackupSelection({
      'general',
      'appearance',
      'playback',
      'danmaku',
      'recommendFilter',
      'blacklist',
      'aiExplicit',
    }),
  });

  static const S3BackupConfig empty = S3BackupConfig();

  final String displayName;
  final String endpoint;
  final String bucket;
  final String region;
  final String prefix;
  final S3AddressingMode addressing;

  /// Explicit opt-in for an HTTP S3 endpoint on a private network. Credentials
  /// and object bodies travel in clear text on that hop; public HTTP hosts
  /// remain rejected.
  final bool allowInsecureHttp;
  final int timeoutSeconds;
  final bool autoEnabled;
  final bool autoWifiOnly;
  final int autoIntervalHours;
  final int retainAutoSnapshots;
  final BackupSelection selection;

  bool get isConfigured =>
      endpoint.trim().isNotEmpty &&
      bucket.trim().isNotEmpty &&
      region.trim().isNotEmpty;

  String get normalizedPrefix => _cleanPrefix(prefix);

  static String _cleanPrefix(String value) {
    var result = value.trim();
    while (result.startsWith('/')) {
      result = result.substring(1);
    }
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    result = result.replaceAll(RegExp(r'/+'), '/');
    final segments = result.split('/');
    if (segments.any((s) => s == '.' || s == '..')) {
      return 'PiliPlusBackups';
    }
    return result.isEmpty ? 'PiliPlusBackups' : result;
  }

  /// The reason this configuration cannot be used, or null.
  String? validationError() {
    final uri = Uri.tryParse(endpoint.trim());
    if (uri == null || uri.host.isEmpty || uri.scheme.isEmpty) {
      return 'Endpoint 无效';
    }
    final loopback = isLoopbackHost(uri.host);
    final allowedHttp =
        loopback || (allowInsecureHttp && isPrivateNetworkHost(uri.host));
    if (uri.scheme != 'https' && !(uri.scheme == 'http' && allowedHttp)) {
      return allowInsecureHttp
          ? '明文 HTTP 仅允许私有网络地址；公网地址必须使用 HTTPS'
          : 'Endpoint 必须使用 HTTPS（本机回环或内网地址需显式允许）';
    }
    if (uri.userInfo.isNotEmpty) {
      return 'Endpoint 不能包含用户名或密钥';
    }
    if (bucket.trim().isEmpty) return 'Bucket 不能为空';
    if (bucket.contains('/') || bucket.contains(' ')) return 'Bucket 名称无效';
    if (region.trim().isEmpty) return 'Region 不能为空';
    if (timeoutSeconds < 5 || timeoutSeconds > 120) return '超时时间需在 5-120 秒';
    if (autoIntervalHours < 1 || autoIntervalHours > 168) {
      return '自动备份间隔需在 1-168 小时';
    }
    if (retainAutoSnapshots < 1 || retainAutoSnapshots > 100) {
      return '保留数量需在 1-100';
    }
    return null;
  }

  S3BackupConfig copyWith({
    String? displayName,
    String? endpoint,
    String? bucket,
    String? region,
    String? prefix,
    S3AddressingMode? addressing,
    bool? allowInsecureHttp,
    int? timeoutSeconds,
    bool? autoEnabled,
    bool? autoWifiOnly,
    int? autoIntervalHours,
    int? retainAutoSnapshots,
    BackupSelection? selection,
  }) => S3BackupConfig(
    displayName: displayName ?? this.displayName,
    endpoint: endpoint ?? this.endpoint,
    bucket: bucket ?? this.bucket,
    region: region ?? this.region,
    prefix: prefix ?? this.prefix,
    addressing: addressing ?? this.addressing,
    allowInsecureHttp: allowInsecureHttp ?? this.allowInsecureHttp,
    timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
    autoEnabled: autoEnabled ?? this.autoEnabled,
    autoWifiOnly: autoWifiOnly ?? this.autoWifiOnly,
    autoIntervalHours: autoIntervalHours ?? this.autoIntervalHours,
    retainAutoSnapshots: retainAutoSnapshots ?? this.retainAutoSnapshots,
    selection: selection ?? this.selection,
  );

  Map<String, dynamic> toMap() => {
    'displayName': displayName,
    'endpoint': endpoint,
    'bucket': bucket,
    'region': region,
    'prefix': prefix,
    'addressing': addressing.id,
    'allowInsecureHttp': allowInsecureHttp,
    'timeoutSeconds': timeoutSeconds,
    'autoEnabled': autoEnabled,
    'autoWifiOnly': autoWifiOnly,
    'autoIntervalHours': autoIntervalHours,
    'retainAutoSnapshots': retainAutoSnapshots,
    'selection': selection.toMap(),
  };

  String toJson() => jsonEncode(toMap());

  static S3BackupConfig fromMap(Object? raw) {
    if (raw is! Map) return empty;
    String str(String key, String fallback) =>
        raw[key] is String ? raw[key] as String : fallback;
    int integer(String key, int fallback, int min, int max) {
      final value = raw[key];
      if (value is! int) return fallback;
      return value.clamp(min, max);
    }

    return S3BackupConfig(
      displayName: str('displayName', ''),
      endpoint: str('endpoint', ''),
      bucket: str('bucket', ''),
      region: str('region', ''),
      prefix: str('prefix', 'PiliPlusBackups'),
      addressing: S3AddressingMode.fromId(raw['addressing']),
      allowInsecureHttp: raw['allowInsecureHttp'] is bool
          ? raw['allowInsecureHttp'] as bool
          : false,
      timeoutSeconds: integer('timeoutSeconds', 20, 5, 120),
      autoEnabled: raw['autoEnabled'] is bool
          ? raw['autoEnabled'] as bool
          : false,
      autoWifiOnly: raw['autoWifiOnly'] is bool
          ? raw['autoWifiOnly'] as bool
          : true,
      autoIntervalHours: integer('autoIntervalHours', 6, 1, 168),
      retainAutoSnapshots: integer('retainAutoSnapshots', 20, 1, 100),
      selection: BackupSelection.fromMap(
        raw['selection'],
      ),
    );
  }
}
