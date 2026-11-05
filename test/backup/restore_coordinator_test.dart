import 'dart:typed_data';

import 'package:PiliPlus/models/backup/backup_snapshot.dart';
import 'package:PiliPlus/utils/backup/backup_history_repository.dart';
import 'package:PiliPlus/utils/backup/restore_coordinator.dart';
import 'package:PiliPlus/utils/backup/restore_planner.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeWriter implements RestoreWriter {
  FakeWriter({this.failOn});
  final String? failOn;
  final Map<String, Object?> values = {};
  bool _failed = false;

  @override
  Future<void> setSetting(String key, Object? value) async {
    if (key == failOn && !_failed) {
      _failed = true;
      throw StateError('boom');
    }
    values[key] = value;
  }

  @override
  Future<void> replaceList(String category, List<Object?> values) async {
    this.values[category] = values;
  }

  @override
  Future<void> replaceProfile(Map<String, dynamic> profile) async {
    values['profile'] = profile;
  }

  @override
  Future<void> setAiSettings(Map<String, dynamic> settings) async {
    values['ai'] = settings;
  }

  @override
  Future<void> mergeProgress(Map<String, int> progress) async {
    values['progress'] = progress;
  }

  @override
  Future<void> installFont(Uint8List bytes, String family) async {
    values['font'] = family;
  }

  @override
  Object? readSetting(String key) => values[key];
}

RestorePlan planWith(List<RestoreChange> changes) => RestorePlan(
  manifest: BackupManifest(
    createdAt: '2026-11-05T00:00:00Z',
    snapshotId: 's1',
    deviceId: 'd1',
    backupSetId: 'b1',
    categories: const ['general'],
  ),
  changes: changes,
  skips: const [],
  selectedCategories: const ['general'],
  requiresRestart: false,
  notes: const [],
);

void main() {
  test('applies settings and leaves a committed journal', () async {
    final repo = BackupHistoryRepository(MemoryBackupMetadataStore());
    final writer = FakeWriter()..values['themeMode'] = 'old';
    final coordinator = RestoreCoordinator(
      repository: repo,
      writer: writer,
    );
    await coordinator.apply(
      planWith([
        const RestoreChange(
          category: 'general',
          key: 'themeMode',
          kind: RestoreChangeKind.setSetting,
          oldValue: 'old',
          newValue: 'new',
        ),
      ]),
    );
    expect(writer.values['themeMode'], 'new');
    expect(repo.journal!['state'], 'committed');
  });

  test('a failed apply rolls back every earlier change', () async {
    final repo = BackupHistoryRepository(MemoryBackupMetadataStore());
    final writer = FakeWriter(failOn: 'b')..values['a'] = 'old-a';
    final coordinator = RestoreCoordinator(
      repository: repo,
      writer: writer,
    );
    await expectLater(
      coordinator.apply(
        planWith([
          const RestoreChange(
            category: 'general',
            key: 'a',
            kind: RestoreChangeKind.setSetting,
            oldValue: 'old-a',
            newValue: 'new-a',
          ),
          const RestoreChange(
            category: 'general',
            key: 'b',
            kind: RestoreChangeKind.setSetting,
            oldValue: 'old-b',
            newValue: 'new-b',
          ),
        ]),
      ),
      throwsA(isA<RestoreFailure>()),
    );
    expect(writer.values['a'], 'old-a');
    expect(repo.journal!['state'], 'rolledBack');
  });

  test('recovery rolls back an interrupted journal before startup', () async {
    final store = MemoryBackupMetadataStore();
    final repo = BackupHistoryRepository(store);
    await repo.writeJournal({
      'state': 'applying',
      'changes': [
        {
          'category': 'general',
          'key': 'a',
          'kind': 'setSetting',
          'old': 'old',
          'new': 'new',
        },
      ],
    });
    final writer = FakeWriter()..values['a'] = 'new';
    final coordinator = RestoreCoordinator(
      repository: repo,
      writer: writer,
    );
    final result = await coordinator.recoverIfNeeded();
    expect(result, RecoveryResult.rolledBack);
    expect(writer.values['a'], 'old');
  });

  test('a committed journal is cleaned on recovery', () async {
    final repo = BackupHistoryRepository(MemoryBackupMetadataStore());
    await repo.writeJournal({'state': 'committed'});
    final coordinator = RestoreCoordinator(
      repository: repo,
      writer: FakeWriter(),
    );
    expect(await coordinator.recoverIfNeeded(), RecoveryResult.completed);
    expect(repo.journal, isNull);
  });
}
