import 'dart:typed_data';

import 'package:PiliPlus/models/ai_recommend/ai_recommend_settings.dart';
import 'package:PiliPlus/models/ai_recommend/interest_profile.dart';
import 'package:PiliPlus/models/backup/backup_config.dart';
import 'package:PiliPlus/utils/backup/backup_snapshot_builder.dart';
import 'package:PiliPlus/utils/ai_recommend/interest_profile_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final setting = <String, Object?>{
    'appRcmd': true,
    'savedRcmdTip': Object(),
    'webdavPassword': 'should-not-leak',
    'unsupported': Object(),
  };
  final profile = InterestProfile.empty('uid:7').copyWith(
    topics: {
      'interest_x': TopicPreference(
        id: 'interest_x',
        label: 'Flutter',
        recent: 0.5,
        long: 0.4,
        confidence: 0.7,
        hits: 1,
        updatedAtMs: 1,
      ),
    },
  );

  BackupSnapshotBuilder builder(DateTime now) => BackupSnapshotBuilder(
    readSetting: (key) => setting[key],
    readVideoSetting: (key) => null,
    readBlacklist: () => [3, 1, 2],
    readSearchHistory: () => ['a', 'b'],
    readReplies: () => const [],
    readWatchProgress: () => {'1': 1000},
    readFont: () => Uint8List.fromList([1, 2, 3]),
    readAiSettings: () => const AiRecommendSettings(
      enabled: true,
      wantTags: ['Flutter'],
      baseUrl: 'https://example.com',
      model: 'm',
    ),
    readAiProfile: () async => profile,
    recommendScope: 'uid:7',
    platform: 'ios',
    clock: () => now,
  );

  test('exports only registered keys and skips unsupported values', () async {
    final draft = await builder(DateTime(2026, 11, 5)).build(
      selection: const BackupSelection({
        'general',
        'blacklist',
        'aiExplicit',
        'font',
      }),
      snapshotId: 's1',
      deviceId: 'd1',
      backupSetId: 'b1',
    );
    final general = draft.categories['general'] as Map;
    expect(general['appRcmd'], isTrue);
    expect(general.containsKey('savedRcmdTip'), isFalse);
    expect(general.containsKey('webdavPassword'), isFalse);
    expect(general.containsKey('unsupported'), isFalse);
    expect(draft.categories['blacklist'], {
      'mids': [1, 2, 3],
    });
    final ai = draft.categories['aiExplicit'] as Map;
    expect(ai['enabled'], isTrue);
    expect(ai.containsKey('apiKey'), isFalse);
    expect(draft.font, isNotNull);
    expect(draft.warnings.any((w) => w.contains('savedRcmdTip')), isTrue);
  });

  test('fingerprint ignores time, snapshot id and export metadata', () async {
    final first = await builder(DateTime(2026, 11, 5)).build(
      selection: const BackupSelection({'general'}),
      snapshotId: 's1',
      deviceId: 'd1',
      backupSetId: 'b1',
    );
    final second = await builder(DateTime(2027, 1, 1)).build(
      selection: const BackupSelection({'general'}),
      snapshotId: 's2',
      deviceId: 'd2',
      backupSetId: 'b2',
    );
    expect(first.contentFingerprint, second.contentFingerprint);
  });

  test('profile category carries the account scope', () async {
    final draft = await builder(DateTime(2026, 11, 5)).build(
      selection: const BackupSelection({'aiProfile'}),
      snapshotId: 's1',
      deviceId: 'd1',
      backupSetId: 'b1',
    );
    final data = draft.categories['aiProfile'] as Map;
    expect(data['accountScope'], 'uid:7');
    expect((data['profile'] as Map)['topics'], isNotEmpty);
    expect(draft.manifest.profileScope, 'uid:7');
  });

  test('missing font is reported, not invented', () async {
    final b = BackupSnapshotBuilder(
      readSetting: (key) => null,
      readVideoSetting: (key) => null,
      readBlacklist: () => const [],
      readSearchHistory: () => const [],
      readReplies: () => const [],
      readWatchProgress: () => const {},
      readFont: () => null,
      readAiSettings: () => AiRecommendSettings.defaults,
      readAiProfile: () async => null,
      recommendScope: 'anon',
      platform: 'ios',
    );
    final draft = await b.build(
      selection: const BackupSelection({'font'}),
      snapshotId: 's1',
      deviceId: 'd1',
      backupSetId: 'b1',
    );
    expect(draft.font, isNull);
    expect(draft.warnings.any((w) => w.contains('字体')), isTrue);
  });
}
