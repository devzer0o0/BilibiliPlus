import 'dart:convert';
import 'dart:typed_data';

import 'package:PiliPlus/utils/backup/backup_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('encrypt/decrypt round-trips and uses a fresh nonce', () async {
    final key = BackupCrypto.generateKey();
    final plaintext = Uint8List.fromList(utf8.encode('hello backup'));
    final first = await BackupCrypto.encrypt(plaintext, key);
    final second = await BackupCrypto.encrypt(plaintext, key);
    expect(first.sublist(0, 4), BackupCrypto.magic);
    expect(first, isNot(equals(second)));
    expect(await BackupCrypto.decrypt(first, key), plaintext);
  });

  test('wrong key is rejected before parsing', () async {
    final key = BackupCrypto.generateKey();
    final other = BackupCrypto.generateKey();
    final bytes = await BackupCrypto.encrypt(
      Uint8List.fromList(utf8.encode('x')),
      key,
    );
    await expectLater(
      BackupCrypto.decrypt(bytes, other),
      throwsA(isA<BackupCryptoException>()),
    );
  });

  test('tampered ciphertext fails the authentication tag', () async {
    final key = BackupCrypto.generateKey();
    final bytes = await BackupCrypto.encrypt(
      Uint8List.fromList(utf8.encode('payload')),
      key,
    );
    bytes[bytes.length - 17] ^= 0xFF;
    await expectLater(
      BackupCrypto.decrypt(bytes, key),
      throwsA(isA<BackupCryptoException>()),
    );
  });

  test('tampered header fails authentication', () async {
    final key = BackupCrypto.generateKey();
    final bytes = await BackupCrypto.encrypt(
      Uint8List.fromList(utf8.encode('payload')),
      key,
    );
    final headerLen =
        (bytes[4] << 24) | (bytes[5] << 16) | (bytes[6] << 8) | bytes[7];
    final header = utf8.decode(bytes.sublist(8, 8 + headerLen));
    final changed = header.replaceFirst('AES-256-GCM', 'AES-256-GCM ');
    final headerBytes = utf8.encode(changed);
    final rebuilt = BytesBuilder()
      ..add(bytes.sublist(0, 4))
      ..add([
        (headerBytes.length >> 24) & 0xFF,
        (headerBytes.length >> 16) & 0xFF,
        (headerBytes.length >> 8) & 0xFF,
        headerBytes.length & 0xFF,
      ])
      ..add(headerBytes)
      ..add(bytes.sublist(8 + headerLen));
    await expectLater(
      BackupCrypto.decrypt(rebuilt.takeBytes(), key),
      throwsA(isA<BackupCryptoException>()),
    );
  });

  test('truncated input is rejected', () async {
    final key = BackupCrypto.generateKey();
    final bytes = await BackupCrypto.encrypt(
      Uint8List.fromList(utf8.encode('payload')),
      key,
    );
    await expectLater(
      BackupCrypto.decrypt(bytes.sublist(0, bytes.length - 20), key),
      throwsA(isA<BackupCryptoException>()),
    );
  });

  test('recovery code round-trips and is checksummed', () {
    final key = BackupCrypto.generateKey();
    final code = BackupCrypto.encodeRecoveryCode(key);
    expect(code, startsWith('PPB1-'));
    expect(BackupCrypto.decodeRecoveryCode(code), key);
    expect(
      BackupCrypto.decodeRecoveryCode(code.toLowerCase().replaceAll('-', ' ')),
      key,
    );
    final bad = code.substring(0, code.length - 2) + 'AA';
    expect(
      () => BackupCrypto.decodeRecoveryCode(bad),
      throwsA(isA<BackupCryptoException>()),
    );
    expect(
      () => BackupCrypto.decodeRecoveryCode('PPB1-NOT-A-CODE'),
      throwsA(isA<BackupCryptoException>()),
    );
  });

  test('key id is stable and envelope inspection needs no key', () async {
    final key = BackupCrypto.generateKey();
    final bytes = await BackupCrypto.encrypt(
      Uint8List.fromList(utf8.encode('x')),
      key,
    );
    final envelope = BackupCrypto.inspect(bytes);
    expect(envelope.keyId, BackupCrypto.keyId(key));
    expect(envelope.version, 1);
  });
}
