// ignore_for_file: prefer_interpolation_to_compose_strings
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

class BackupCryptoException implements Exception {
  const BackupCryptoException(this.message);

  final String message;

  @override
  String toString() => 'BackupCryptoException(' + message + ')';
}

class BackupEnvelope {
  const BackupEnvelope({
    required this.version,
    required this.algorithm,
    required this.keyId,
    required this.nonce,
  });

  final int version;
  final String algorithm;
  final String keyId;
  final Uint8List nonce;
}

/// AES-256-GCM envelope for a compressed backup.
///
/// Layout: magic (4) | header length (4, big endian) | header JSON | ciphertext
/// | mac (16). The header is the AAD, so changing the version, algorithm,
/// key id or nonce invalidates authentication before anything is parsed.
abstract final class BackupCrypto {
  static const List<int> magic = [0x50, 0x50, 0x42, 0x4B];
  static const int version = 1;
  static const String algorithm = 'AES-256-GCM';
  static const int keyLength = 32;
  static const int nonceLength = 12;
  static const int macLength = 16;
  static const int maxHeaderBytes = 4096;

  static Uint8List generateKey() {
    final random = math.Random.secure();
    return Uint8List.fromList(
      List<int>.generate(keyLength, (_) => random.nextInt(256)),
    );
  }

  static String keyId(Uint8List key) =>
      sha256.convert(key).toString().substring(0, 16);

  static String keyToBase64(Uint8List key) => base64Encode(key);

  static Uint8List keyFromBase64(String value) {
    final bytes = base64Decode(value.trim());
    if (bytes.length != keyLength) {
      throw const BackupCryptoException('恢复密钥长度不正确');
    }
    return Uint8List.fromList(bytes);
  }

  static Future<Uint8List> encrypt(
    Uint8List plaintext,
    Uint8List key, {
    Uint8List? nonce,
  }) async {
    if (key.length != keyLength) {
      throw const BackupCryptoException('恢复密钥长度不正确');
    }
    final random = math.Random.secure();
    final iv =
        nonce ??
        Uint8List.fromList(
          List<int>.generate(nonceLength, (_) => random.nextInt(256)),
        );
    final header = <String, dynamic>{
      'alg': algorithm,
      'keyId': keyId(key),
      'nonce': base64Encode(iv),
      'v': version,
    };
    final headerBytes = utf8.encode(jsonEncode(header));
    final box = await AesGcm.with256bits().encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: iv,
      aad: headerBytes,
    );
    final output = BytesBuilder(copy: false)
      ..add(magic)
      ..add(_uint32(headerBytes.length))
      ..add(headerBytes)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return output.takeBytes();
  }

  static Future<Uint8List> decrypt(
    Uint8List bytes,
    Uint8List key,
  ) async {
    final envelope = inspect(bytes);
    if (envelope.keyId != keyId(key)) {
      throw const BackupCryptoException('恢复码与快照不匹配');
    }
    final headerLength = _readUint32(bytes, magic.length);
    final headerStart = magic.length + 4;
    final headerEnd = headerStart + headerLength;
    if (headerEnd + macLength > bytes.length) {
      throw const BackupCryptoException('快照被截断');
    }
    final headerBytes = bytes.sublist(headerStart, headerEnd);
    final cipherText = bytes.sublist(headerEnd, bytes.length - macLength);
    final mac = bytes.sublist(bytes.length - macLength);
    try {
      final clear = await AesGcm.with256bits().decrypt(
        SecretBox(cipherText, nonce: envelope.nonce, mac: Mac(mac)),
        secretKey: SecretKey(key),
        aad: headerBytes,
      );
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw const BackupCryptoException('认证失败：快照被篡改或恢复码错误');
    } on Object catch (e) {
      if (e is BackupCryptoException) rethrow;
      throw const BackupCryptoException('解密失败');
    }
  }

  /// Reads only the public envelope. It is used by the restore screen to tell
  /// the user which recovery key id a snapshot needs, without decrypting it.
  static BackupEnvelope inspect(Uint8List bytes) {
    if (bytes.length < magic.length + 4 + macLength) {
      throw const BackupCryptoException('不是有效的备份快照');
    }
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) {
        throw const BackupCryptoException('不是有效的备份快照');
      }
    }
    final headerLength = _readUint32(bytes, magic.length);
    if (headerLength <= 0 || headerLength > maxHeaderBytes) {
      throw const BackupCryptoException('快照头部不合法');
    }
    final headerStart = magic.length + 4;
    final headerEnd = headerStart + headerLength;
    if (headerEnd + macLength > bytes.length) {
      throw const BackupCryptoException('快照被截断');
    }
    final Object? header;
    try {
      header = jsonDecode(utf8.decode(bytes.sublist(headerStart, headerEnd)));
    } on Object catch (_) {
      throw const BackupCryptoException('快照头部不合法');
    }
    if (header is! Map || header['v'] is! int) {
      throw const BackupCryptoException('快照头部不合法');
    }
    if (header['v'] != version) {
      throw const BackupCryptoException('不支持的快照加密版本');
    }
    if (header['alg'] != algorithm) {
      throw const BackupCryptoException('不支持的加密算法');
    }
    final keyIdValue = header['keyId'];
    final nonceValue = header['nonce'];
    if (keyIdValue is! String || nonceValue is! String) {
      throw const BackupCryptoException('快照头部不完整');
    }
    final nonce = base64Decode(nonceValue);
    if (nonce.length != nonceLength) {
      throw const BackupCryptoException('快照 nonce 不合法');
    }
    return BackupEnvelope(
      version: version,
      algorithm: algorithm,
      keyId: keyIdValue,
      nonce: Uint8List.fromList(nonce),
    );
  }

  /// A versioned, checksummed recovery code intended for a password manager.
  static String encodeRecoveryCode(Uint8List key) {
    if (key.length != keyLength) {
      throw const BackupCryptoException('恢复密钥长度不正确');
    }
    final checksum = sha256.convert(key).bytes.sublist(0, 2);
    final payload = Uint8List.fromList([...key, ...checksum]);
    final encoded = _base32Encode(payload);
    final groups = <String>[];
    for (var i = 0; i < encoded.length; i += 5) {
      groups.add(
        encoded.substring(
          i,
          math.min(i + 5, encoded.length),
        ),
      );
    }
    return 'PPB1-' + groups.join('-');
  }

  static Uint8List decodeRecoveryCode(String code) {
    var raw = code.trim().toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    if (raw.startsWith('PPB1')) raw = raw.substring(4);
    final bytes = _base32Decode(raw);
    if (bytes.length != keyLength + 2) {
      throw const BackupCryptoException('恢复码长度不正确');
    }
    final key = Uint8List.fromList(bytes.sublist(0, keyLength));
    final checksum = bytes.sublist(keyLength);
    final expected = sha256.convert(key).bytes.sublist(0, 2);
    if (checksum[0] != expected[0] || checksum[1] != expected[1]) {
      throw const BackupCryptoException('恢复码校验失败，请检查是否输错');
    }
    return key;
  }

  static const String _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  static String _base32Encode(List<int> bytes) {
    var buffer = 0;
    var bits = 0;
    final output = StringBuffer();
    for (final byte in bytes) {
      buffer = (buffer << 8) | (byte & 0xFF);
      bits += 8;
      while (bits >= 5) {
        output.write(_alphabet[(buffer >> (bits - 5)) & 0x1F]);
        bits -= 5;
      }
    }
    if (bits > 0) {
      output.write(_alphabet[(buffer << (5 - bits)) & 0x1F]);
    }
    return output.toString();
  }

  static List<int> _base32Decode(String input) {
    var buffer = 0;
    var bits = 0;
    final output = <int>[];
    for (final code in input.codeUnits) {
      final index = _alphabet.indexOf(String.fromCharCode(code));
      if (index < 0) {
        throw const BackupCryptoException('恢复码包含无效字符');
      }
      buffer = (buffer << 5) | index;
      bits += 5;
      if (bits >= 8) {
        output.add((buffer >> (bits - 8)) & 0xFF);
        bits -= 8;
      }
    }
    return output;
  }

  static List<int> _uint32(int value) => [
    (value >> 24) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  ];

  static int _readUint32(List<int> bytes, int offset) {
    if (offset + 4 > bytes.length) {
      throw const BackupCryptoException('快照被截断');
    }
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }
}
