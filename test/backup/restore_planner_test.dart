import 'dart:typed_data';

import 'package:PiliPlus/models/ai_recommend/ai_recommend_settings.dart';
import 'package:PiliPlus/models/ai_recommend/interest_profile.dart';
import 'package:PiliPlus/models/backup/backup_config.dart';
import 'package:PiliPlus/models/backup/backup_snapshot.dart';
import 'package:PiliPlus/utils/backup/restore_planner.dart';
import 'package:flutter_test/flutter_test.dart';

BackupManifest manifest({
  String platform = 'ios',
  List<String> categories = const [],
}) => BackupManifest(
  platform: platform,
  createdAt: '2026-11-05T00:00:00Z',
  snapshotId: 's1',
  deviceId: 'd1',
  backupSetId: 'b1',
  categories: categories,
  schemaVersions: {for (final c in categories) c: 1},
);

RestorePlanner planner({
  Map<String, Object?>? settings,
  List<int> blacklist = const [],
  InterestProfile? profile,
  String scope = 'uid:7',
  String platform = 'ios',
}) {
  final values = settings ?? {};
  return RestorePlanner(
    readSetting: (key) => values[key],
    readBlacklist: () => blacklist,
    readSearchHistory: () => const [],
    readReplies: () => const [],
    readWatchProgress: () => const {},
    readAiSettings: () => AiRecommendSettings.defaults,
    readCurrentProfile: () async => profile,
    targetPlatform: platform,
    targetScope: scope,
    currentFontFamily: null,
  );
}

void main() {
  test('diffs known settings and reports no change when equal', () async {
    final archive = BackupArchive(
      manifest: manifest(categories: ['general']),
      categories: {
        'general': {'appRcmd': false},
      },
    );
    final p = await planner(
      settings: {'appRcmd': true},
    ).plan(archive, selection: const BackupSelection({'general'}));
    expect(p.changes.length, 1);
    expect(p.changes.single.oldValue, true);
    expect(p.changes.single.newValue, false);
    expect(p.requiresRestart, isFalse);

    final same = await planner(
      settings: {'appRcmd': false},
    ).plan(archive, selection: const BackupSelection({'general'}));
    expect(same.changes, isEmpty);
  });

  test('unknown keys and credential-like keys are skipped', () async {
    final archive = BackupArchive(
      manifest: manifest(categories: ['general']),
      categories: {
        'general': {
          'notRegistered': 1,
          'webdavPassword': 'x',
        },
      },
    );
    final p = await planner().plan(
      archive,
      selection: const BackupSelection({'general'}),
    );
    expect(p.changes, isEmpty);
    expect(p.skips.length, 2);
    expect(p.skips.every((s) => s.reason.isNotEmpty), isTrue);
  });

  test('cross-platform appearance is skipped, not coerced', () async {
    final archive = BackupArchive(
      manifest: manifest(platform: 'android', categories: ['appearance']),
      categories: {
        'appearance': {'themeMode': 1},
      },
    );
    final p = await planner(platform: 'ios').plan(
      archive,
      selection: const BackupSelection({'appearance'}),
    );
    expect(p.changes, isEmpty);
    expect(p.skips.single.reason, contains('平台'));
  });

  test('AI explicit preference is restored disabled', () async {
    final archive = BackupArchive(
      manifest: manifest(categories: ['aiExplicit']),
      categories: {
        'aiExplicit': const AiRecommendSettings(
          enabled: true,
          wantTags: ['NAS'],
          baseUrl: 'https://example.com',
          model: 'm',
        ).toMap(),
      },
    );
    final p = await planner().plan(
      archive,
      selection: const BackupSelection({'aiExplicit'}),
    );
    final change = p.changes.single;
    expect((change.newValue as Map)['enabled'], isFalse);
    expect((change.newValue as Map)['wantTags'], ['NAS']);
    expect(p.notes.any((n) => n.contains('保持关闭')), isTrue);
    expect(p.requiresRestart, isTrue);
  });

  test('profile from another scope is skipped', () async {
    final archive = BackupArchive(
      manifest: manifest(categories: ['aiProfile']),
      categories: {
        'aiProfile': {
          'accountScope': 'uid:8',
          'profile': InterestProfile.empty('uid:8').toJson(),
        },
      },
    );
    final p = await planner(scope: 'uid:7').plan(
      archive,
      selection: const BackupSelection({'aiProfile'}),
    );
    expect(p.changes, isEmpty);
    expect(p.skips.single.reason, contains('作用域'));
  });

  test('blacklist merge only adds missing ids', () async {
    final archive = BackupArchive(
      manifest: manifest(categories: ['blacklist']),
      categories: {
        'blacklist': {
          'mids': [1, 2, 4],
        },
      },
    );
    final p = await planner(blacklist: [1, 2, 3]).plan(
      archive,
      selection: const BackupSelection({'blacklist'}),
      mergeLists: true,
    );
    expect(p.changes.single.kind, RestoreChangeKind.addToList);
    expect(p.changes.single.newValue, [4]);
  });

  test('empty category is not a delete', () async {
    final archive = BackupArchive(
      manifest: manifest(categories: ['general']),
      categories: {'general': <String, Object?>{}},
    );
    final p = await planner(
      settings: {'appRcmd': true},
    ).plan(archive, selection: const BackupSelection({'general'}));
    expect(p.changes, isEmpty);
    expect(p.skips, isEmpty);
  });

  test('font plan requires the font bytes', () async {
    final archive = BackupArchive(
      manifest: manifest(categories: ['font']),
      categories: {
        'font': {'family': 'MyFont'},
      },
      font: Uint8List.fromList([1, 2, 3]),
    );
    final p = await planner().plan(
      archive,
      selection: const BackupSelection({'font'}),
    );
    expect(p.changes.single.kind, RestoreChangeKind.installFont);
    expect(p.fontFamily, 'MyFont');
  });
}
