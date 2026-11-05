// ignore_for_file: prefer_interpolation_to_compose_strings
import 'dart:math' as math;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract final class SecretKeys {
  static const String aiApiKey = 'ai.apiKey.v1';
  static const String s3AccessKeyId = 's3.accessKeyId.v1';
  static const String s3SecretAccessKey = 's3.secretAccessKey.v1';
  static const String s3SessionToken = 's3.sessionToken.v1';
  static const String backupRecoveryKey = 'backup.recoveryKey.v1';
}

class SecretStoreException implements Exception {
  const SecretStoreException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'SecretStoreException(' + message + ')';
}

/// The only abstraction allowed to touch credentials.
///
/// A failed platform store must surface as an error. There is deliberately no
/// fallback to a Hive box or to plaintext: silently downgrading a key store is
/// worse than refusing to save.
abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);

  /// Round-trips a small marker. Used by the settings pages before claiming
  /// that credentials can be stored on this device.
  Future<void> probe();
}

class FlutterSecretStore implements SecretStore {
  FlutterSecretStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
              synchronizable: false,
            ),
            mOptions: MacOsOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
              synchronizable: false,
            ),
          );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e) {
      throw SecretStoreException('无法读取安全存储', e);
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      throw SecretStoreException('无法写入安全存储', e);
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e) {
      throw SecretStoreException('无法删除安全存储条目', e);
    }
  }

  @override
  Future<void> probe() async {
    final marker =
        'probe-' + math.Random.secure().nextInt(1 << 30).toRadixString(16);
    try {
      await _storage.write(key: 'store.probe', value: marker);
      final read = await _storage.read(key: 'store.probe');
      if (read != marker) {
        throw const SecretStoreException('安全存储回读不一致');
      }
    } catch (e) {
      if (e is SecretStoreException) rethrow;
      throw SecretStoreException('安全存储不可用', e);
    } finally {
      try {
        await _storage.delete(key: 'store.probe');
      } catch (_) {
        // The probe key is harmless; failing to delete it must not mask the
        // real result above.
      }
    }
  }
}

class MemorySecretStore implements SecretStore {
  MemorySecretStore([Map<String, String>? initial]) : _values = {...?initial};

  final Map<String, String> _values;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<void> probe() async {
    await write('store.probe', 'ok');
    if (await read('store.probe') != 'ok') {
      throw const SecretStoreException('安全存储回读不一致');
    }
    await delete('store.probe');
  }
}
