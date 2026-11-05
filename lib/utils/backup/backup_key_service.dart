import 'dart:typed_data';

import 'package:PiliPlus/utils/backup/backup_crypto.dart';
import 'package:PiliPlus/utils/security/secret_store.dart';

class RecoveryKeyInfo {
  const RecoveryKeyInfo({
    required this.key,
    required this.code,
    required this.keyId,
  });

  final Uint8List key;
  final String code;
  final String keyId;
}

class BackupKeyService {
  BackupKeyService(this.secrets);

  final SecretStore secrets;

  Future<Uint8List?> readKey() async {
    final raw = await secrets.read(SecretKeys.backupRecoveryKey);
    if (raw == null || raw.trim().isEmpty) return null;
    return BackupCrypto.keyFromBase64(raw);
  }

  Future<String?> keyId() async {
    final key = await readKey();
    return key == null ? null : BackupCrypto.keyId(key);
  }

  /// Generates and stores a key only when none exists. The code is derived from
  /// the key, so every later display shows the same code.
  Future<RecoveryKeyInfo> ensureKey() async {
    var key = await readKey();
    if (key == null) {
      key = BackupCrypto.generateKey();
      await secrets.write(
        SecretKeys.backupRecoveryKey,
        BackupCrypto.keyToBase64(key),
      );
    }
    return RecoveryKeyInfo(
      key: key,
      code: BackupCrypto.encodeRecoveryCode(key),
      keyId: BackupCrypto.keyId(key),
    );
  }

  Future<RecoveryKeyInfo> importCode(String code) async {
    final key = BackupCrypto.decodeRecoveryCode(code);
    await secrets.write(
      SecretKeys.backupRecoveryKey,
      BackupCrypto.keyToBase64(key),
    );
    return RecoveryKeyInfo(
      key: key,
      code: BackupCrypto.encodeRecoveryCode(key),
      keyId: BackupCrypto.keyId(key),
    );
  }
}
