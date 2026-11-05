// ignore_for_file: prefer_interpolation_to_compose_strings
import 'dart:convert';
import 'dart:typed_data';

import 'package:PiliPlus/models/backup/backup_snapshot.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

abstract final class BackupCodec {
  static const int maxCompressedBytes = 32 * 1024 * 1024;
  static const int maxExpandedBytes = 64 * 1024 * 1024;
  static const int maxDataBytes = 16 * 1024 * 1024;
  static const int maxFontBytes = 32 * 1024 * 1024;
  static const int maxEntries = 200;
  static const int maxJsonDepth = 32;
  static const String manifestName = 'manifest.json';
  static const String dataName = 'data.json';
  static const String fontName = 'font.bin';

  static Uint8List encode({
    required BackupManifest manifest,
    required Map<String, Object?> categories,
    Uint8List? font,
  }) {
    final dataJson = canonicalJson(categories);
    final dataBytes = utf8.encode(dataJson);
    if (dataBytes.length > maxDataBytes) {
      throw const BackupFormatException('数据超过单文件上限');
    }
    final fileInfos = <BackupFileInfo>[
      BackupFileInfo(
        name: dataName,
        bytes: dataBytes.length,
        sha256: sha256.convert(dataBytes).toString(),
      ),
    ];
    if (font != null) {
      if (font.length > maxFontBytes) {
        throw const BackupFormatException('字体文件过大');
      }
      fileInfos.add(
        BackupFileInfo(
          name: fontName,
          bytes: font.length,
          sha256: sha256.convert(font).toString(),
        ),
      );
    }
    final contentHash = _contentHash(dataBytes, font);
    final expected = manifest.categories.toSet();
    if (expected.length != categories.keys.length ||
        !expected.containsAll(categories.keys)) {
      throw const BackupFormatException('分类清单与数据不一致');
    }
    final withFiles = manifest.copyWith(
      files: fileInfos,
      contentHash: contentHash,
    );
    final archive = Archive()
      ..add(ArchiveFile.string(manifestName, withFiles.toJsonString()))
      ..add(ArchiveFile.bytes(dataName, dataBytes));
    if (font != null) {
      archive.add(ArchiveFile.bytes(fontName, font));
    }
    final encoded = ZipEncoder().encode(archive);
    if (encoded.length > maxCompressedBytes) {
      throw const BackupFormatException('归档超过上传上限');
    }
    return Uint8List.fromList(encoded);
  }

  static BackupArchive decode(Uint8List zipBytes) {
    if (zipBytes.length > maxCompressedBytes) {
      throw const BackupFormatException('归档超过大小上限');
    }
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes, verify: false);
    } on Object catch (_) {
      throw const BackupFormatException('不是有效的归档文件');
    }
    if (archive.length > maxEntries) {
      throw const BackupFormatException('归档条目过多');
    }

    final seen = <String>{};
    var declaredTotal = 0;
    for (final file in archive.files) {
      final name = file.name;
      _checkName(name);
      if (!seen.add(name)) {
        throw const BackupFormatException('归档包含重复条目');
      }
      if (!_allowedNames.contains(name)) {
        throw const BackupFormatException('归档包含不允许的文件');
      }
      if (name == dataName && file.size > maxDataBytes) {
        throw const BackupFormatException('数据文件超限');
      }
      if (name == fontName && file.size > maxFontBytes) {
        throw const BackupFormatException('字体文件超限');
      }
      declaredTotal += file.size;
      if (declaredTotal > maxExpandedBytes) {
        throw const BackupFormatException('解压后总量超限');
      }
    }
    // The declared size is not trusted on its own. A high global expansion
    // ratio is rejected before decompressing; actual bytes are checked below.
    if (declaredTotal > 1024 * 1024 &&
        zipBytes.isNotEmpty &&
        declaredTotal ~/ zipBytes.length > 300) {
      throw const BackupFormatException('压缩比异常');
    }

    final manifestFile = archive.find(manifestName);
    final dataFile = archive.find(dataName);
    if (manifestFile == null || dataFile == null) {
      throw const BackupFormatException('归档缺少 manifest 或 data');
    }
    final manifestBytes = Uint8List.fromList(manifestFile.content);
    final dataBytes = Uint8List.fromList(dataFile.content);
    if (dataBytes.length > maxDataBytes) {
      throw const BackupFormatException('数据文件超限');
    }

    final Object? manifestJson;
    try {
      manifestJson = jsonDecode(utf8.decode(manifestBytes));
    } on Object catch (_) {
      throw const BackupFormatException('manifest 不是有效 JSON');
    }
    final manifest = BackupManifest.fromJson(manifestJson);
    if (manifest == null) {
      throw const BackupFormatException('manifest 结构不合法');
    }
    if (manifest.formatVersion <= 0 ||
        manifest.formatVersion > BackupManifest.currentFormatVersion) {
      throw BackupFormatException(
        '归档格式版本过新（' + manifest.formatVersion.toString() + '）',
      );
    }
    if (!_checkDepth(manifestJson)) {
      throw const BackupFormatException('manifest 嵌套过深');
    }

    final actualDataHash = sha256.convert(dataBytes).toString();
    final dataInfo = manifest.files.where((f) => f.name == dataName);
    if (dataInfo.length != 1 || dataInfo.first.sha256 != actualDataHash) {
      throw const BackupFormatException('data.json 校验失败');
    }
    if (dataInfo.first.bytes != dataBytes.length) {
      throw const BackupFormatException('data.json 大小不符');
    }

    Uint8List? font;
    if (archive.find(fontName) case final fontFile?) {
      font = Uint8List.fromList(fontFile.content);
      if (font.length > maxFontBytes) {
        throw const BackupFormatException('字体文件超限');
      }
      final fontInfo = manifest.files.where((f) => f.name == fontName);
      if (fontInfo.length != 1 ||
          fontInfo.first.sha256 != sha256.convert(font).toString() ||
          fontInfo.first.bytes != font.length) {
        throw const BackupFormatException('字体校验失败');
      }
    }
    if (manifest.files.any((f) => f.name != dataName && f.name != fontName)) {
      throw const BackupFormatException('manifest 列出了未知文件');
    }

    final Object? dataJson;
    try {
      dataJson = jsonDecode(utf8.decode(dataBytes));
    } on Object catch (_) {
      throw const BackupFormatException('data.json 不是有效 JSON');
    }
    if (dataJson is! Map) {
      throw const BackupFormatException('data.json 结构不合法');
    }
    if (!_checkDepth(dataJson)) {
      throw const BackupFormatException('data.json 嵌套过深');
    }
    final categories = <String, Object?>{};
    for (final entry in dataJson.entries) {
      if (entry.key is! String) {
        throw const BackupFormatException('分类名必须是字符串');
      }
      categories[entry.key as String] = entry.value;
    }
    final expected = manifest.categories.toSet();
    if (expected.length != categories.keys.length ||
        !expected.containsAll(categories.keys)) {
      throw const BackupFormatException('manifest 与数据分类不一致');
    }
    if (manifest.contentHash != _contentHash(dataBytes, font)) {
      throw const BackupFormatException('内容哈希校验失败');
    }

    return BackupArchive(
      manifest: manifest,
      categories: categories,
      font: font,
    );
  }

  static const Set<String> _allowedNames = {manifestName, dataName, fontName};

  static void _checkName(String name) {
    if (name.isEmpty ||
        name.startsWith('/') ||
        name.startsWith('\\') ||
        name.contains('..') ||
        name.contains('\\') ||
        name.contains('\u0000')) {
      throw const BackupFormatException('归档条目路径不合法');
    }
  }

  static bool _checkDepth(Object? value, [int depth = 0]) {
    if (depth > maxJsonDepth) return false;
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key is! String) return false;
        if (!_checkDepth(entry.value, depth + 1)) return false;
      }
    } else if (value is List) {
      for (final entry in value) {
        if (!_checkDepth(entry, depth + 1)) return false;
      }
    }
    return true;
  }

  static String canonicalJson(Object? value) => jsonEncode(_canonical(value));

  static Object? _canonical(Object? value) {
    if (value is Map) {
      if (value.keys.any((key) => key is! String)) {
        throw const BackupFormatException('Map 键必须是字符串');
      }
      final keys = value.keys.cast<String>().toList()..sort();
      final result = <String, Object?>{};
      for (final key in keys) {
        result[key] = _canonical(value[key]);
      }
      return result;
    }
    if (value is List) return value.map(_canonical).toList();
    if (value is num) {
      if (value is double && (value.isNaN || value.isInfinite)) {
        throw const BackupFormatException('数值不可序列化');
      }
      return value;
    }
    if (value == null || value is bool || value is String) return value;
    throw const BackupFormatException('值不是可备份的类型');
  }

  static String _contentHash(List<int> dataBytes, Uint8List? font) {
    final fontHash = font == null ? '' : sha256.convert(font).toString();
    return sha256
            .convert(utf8.encode(fontHash + '|'))
            .toString()
            .substring(0, 32) +
        sha256.convert(dataBytes).toString().substring(0, 32);
  }
}
