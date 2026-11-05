import 'dart:convert';
import 'dart:typed_data';

import 'package:PiliPlus/models/backup/backup_snapshot.dart';
import 'package:PiliPlus/utils/backup/backup_codec.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

BackupManifest manifest({
  int version = 1,
  List<String> categories = const ['general'],
}) => BackupManifest(
  formatVersion: version,
  createdAt: '2026-11-05T00:00:00Z',
  snapshotId: 's1',
  deviceId: 'd1',
  backupSetId: 'b1',
  categories: categories,
  platform: 'ios',
);

void main() {
  test('round-trips categories and font', () {
    final font = Uint8List.fromList(List<int>.generate(100, (i) => i));
    final bytes = BackupCodec.encode(
      manifest: manifest(categories: ['general', 'font']),
      categories: {
        'general': {'a': 1, 'b': true},
        'font': {'family': 'MyFont'},
      },
      font: font,
    );
    final decoded = BackupCodec.decode(bytes);
    expect(decoded.categories['general'], {'a': 1, 'b': true});
    expect(decoded.font, font);
    expect(decoded.manifest.contentHash, isNotEmpty);
  });

  test('canonical JSON sorts keys and is stable', () {
    expect(
      BackupCodec.canonicalJson({
        'b': 1,
        'a': {'d': 2, 'c': 3},
      }),
      '{"a":{"c":3,"d":2},"b":1}',
    );
  });

  test('category list must match data exactly', () {
    expect(
      () => BackupCodec.encode(
        manifest: manifest(categories: ['general', 'playback']),
        categories: {
          'general': {'a': 1},
        },
      ),
      throwsA(isA<BackupFormatException>()),
    );
  });

  test('newer format version is rejected', () {
    final bytes = BackupCodec.encode(
      manifest: manifest(version: 2),
      categories: {
        'general': {'a': 1},
      },
    );
    expect(
      () => BackupCodec.decode(bytes),
      throwsA(isA<BackupFormatException>()),
    );
  });

  test('path traversal and unknown entries are rejected', () {
    final archive = Archive()
      ..add(ArchiveFile.string('../evil', 'x'))
      ..add(ArchiveFile.string('manifest.json', '{}'))
      ..add(ArchiveFile.string('data.json', '{}'));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    expect(
      () => BackupCodec.decode(bytes),
      throwsA(isA<BackupFormatException>()),
    );
  });

  test('duplicate entries are rejected', () {
    final archive = Archive()
      ..add(ArchiveFile.string('manifest.json', '{}'))
      ..add(ArchiveFile.string('data.json', '{}'))
      ..add(ArchiveFile.string('data.json', '{}'));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    expect(
      () => BackupCodec.decode(bytes),
      throwsA(isA<BackupFormatException>()),
    );
  });

  test('tampered data fails its hash before any restore', () {
    final valid = BackupCodec.encode(
      manifest: manifest(),
      categories: {
        'general': {'a': 1},
      },
    );
    final decoded = ZipDecoder().decodeBytes(valid);
    final rebuilt = Archive();
    for (final file in decoded.files) {
      if (file.name == 'data.json') {
        rebuilt.add(ArchiveFile.string('data.json', '{"general":{}}'));
      } else {
        rebuilt.add(file);
      }
    }
    final tampered = Uint8List.fromList(ZipEncoder().encode(rebuilt));
    expect(
      () => BackupCodec.decode(tampered),
      throwsA(isA<BackupFormatException>()),
    );
  });

  test('oversized archive is rejected before decoding', () {
    final bytes = Uint8List(BackupCodec.maxCompressedBytes + 1);
    expect(
      () => BackupCodec.decode(bytes),
      throwsA(isA<BackupFormatException>()),
    );
  });

  test('high expansion ratio is rejected', () {
    final zeros = Uint8List(2 * 1024 * 1024);
    final archive = Archive()
      ..add(
        ArchiveFile.string(
          'manifest.json',
          jsonEncode(manifest().toJson()),
        ),
      )
      ..add(ArchiveFile.bytes('data.json', zeros));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    expect(
      () => BackupCodec.decode(bytes),
      throwsA(isA<BackupFormatException>()),
    );
  });
}
