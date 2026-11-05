// ignore_for_file: prefer_interpolation_to_compose_strings, unnecessary_lambdas
import 'dart:convert';
import 'dart:typed_data';

import 'package:PiliPlus/utils/backup/backup_history_repository.dart';
import 'package:PiliPlus/utils/backup/restore_planner.dart';

class RestoreFailure implements Exception {
  const RestoreFailure(this.message, {this.rollbackComplete = false});

  final String message;
  final bool rollbackComplete;

  @override
  String toString() => 'RestoreFailure(' + message + ')';
}

abstract interface class RestoreWriter {
  Future<void> setSetting(String key, Object? value);
  Future<void> replaceList(String category, List<Object?> values);
  Future<void> replaceProfile(Map<String, dynamic> profile);
  Future<void> setAiSettings(Map<String, dynamic> settings);
  Future<void> mergeProgress(Map<String, int> values);
  Future<void> installFont(Uint8List bytes, String family);
  Object? readSetting(String key);
}

/// Applies a RestorePlan through a durable journal.
///
/// Hive boxes are not a cross-box transaction. The journal is therefore written
/// before any change, and a crash leaves enough information to roll back. The
/// startup hook calls [recoverIfNeeded] before controllers read these settings.
class RestoreCoordinator {
  RestoreCoordinator({
    required this.repository,
    required this.writer,
    Future<void> Function(RestorePlan plan)? onApplied,
  }) : onApplied = onApplied ?? _noop;

  final BackupHistoryRepository repository;
  final RestoreWriter writer;
  final Future<void> Function(RestorePlan plan) onApplied;

  static Future<void> _noop(RestorePlan plan) async {}

  Future<void> apply(
    RestorePlan plan, {
    Uint8List? fontBytes,
  }) async {
    if (plan.isEmpty) return;
    final journal = <String, dynamic>{
      'state': 'preparing',
      'snapshotId': plan.manifest.snapshotId,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'requiresRestart': plan.requiresRestart,
      'changes': plan.changes.map(_changeToJson).toList(),
    };
    await repository.writeJournal(journal);
    journal['state'] = 'applying';
    await repository.writeJournal(journal);

    try {
      for (final change in plan.changes) {
        await _applyChange(change, fontBytes: fontBytes);
      }
      await _verify(plan);
      journal['state'] = 'committed';
      journal['committedAt'] = DateTime.now().toUtc().toIso8601String();
      await repository.writeJournal(journal);
      await onApplied(plan);
    } on Object catch (e) {
      final complete = await _rollback(journal);
      journal['state'] = complete ? 'rolledBack' : 'rollbackIncomplete';
      journal['error'] = e.toString();
      await repository.writeJournal(journal);
      throw RestoreFailure(
        complete ? '恢复失败，已回滚到恢复前状态' : '恢复失败，回滚不完整，请重新打开应用',
        rollbackComplete: complete,
      );
    }
  }

  /// Called early in startup, before settings-dependent controllers.
  Future<RecoveryResult> recoverIfNeeded() async {
    final journal = repository.journal;
    if (journal == null) return RecoveryResult.none;
    final state = journal['state'];
    if (state == 'committed') {
      await repository.clearJournal();
      return RecoveryResult.completed;
    }
    if (state == 'preparing' || state == 'applying') {
      final complete = await _rollback(journal);
      journal['state'] = complete ? 'rolledBack' : 'rollbackIncomplete';
      await repository.writeJournal(journal);
      return complete ? RecoveryResult.rolledBack : RecoveryResult.failed;
    }
    return RecoveryResult.none;
  }

  Future<void> _applyChange(
    RestoreChange change, {
    Uint8List? fontBytes,
  }) async {
    switch (change.kind) {
      case RestoreChangeKind.setSetting:
        await writer.setSetting(change.key, change.newValue);
      case RestoreChangeKind.addToList:
        final old = change.oldValue is List
            ? change.oldValue as List
            : const [];
        final added = change.newValue is List
            ? change.newValue as List
            : const [];
        await writer.replaceList(change.category, [...old, ...added]);
      case RestoreChangeKind.replaceList:
        await writer.replaceList(
          change.category,
          change.newValue is List ? change.newValue as List : const [],
        );
      case RestoreChangeKind.replaceProfile:
        if (change.newValue is Map) {
          await writer.replaceProfile(
            Map<String, dynamic>.from(change.newValue as Map),
          );
        }
      case RestoreChangeKind.replaceAiSettings:
        if (change.newValue is Map) {
          await writer.setAiSettings(
            Map<String, dynamic>.from(change.newValue as Map),
          );
        }
      case RestoreChangeKind.mergeProgress:
        final values = change.newValue is Map
            ? (change.newValue as Map).map(
                (key, value) =>
                    MapEntry(key.toString(), value is int ? value : 0),
              )
            : <String, int>{};
        await writer.mergeProgress(values);
      case RestoreChangeKind.installFont:
        if (fontBytes == null) {
          throw const RestoreFailure('字体文件缺失');
        }
        final family = change.newValue is String
            ? change.newValue as String
            : '';
        await writer.installFont(fontBytes, family);
    }
  }

  Future<void> _verify(RestorePlan plan) async {
    for (final change in plan.changes) {
      if (change.kind != RestoreChangeKind.setSetting) continue;
      final actual = writer.readSetting(change.key);
      if (!_jsonEquals(actual, change.newValue)) {
        throw const RestoreFailure('写入后回读不一致');
      }
    }
  }

  Future<bool> _rollback(Map<String, dynamic> journal) async {
    final raw = journal['changes'];
    if (raw is! List) return true;
    var complete = true;
    for (final item in raw.reversed) {
      if (item is! Map) continue;
      final change = _changeFromJson(item);
      if (change == null) {
        complete = false;
        continue;
      }
      try {
        switch (change.kind) {
          case RestoreChangeKind.setSetting:
            await writer.setSetting(change.key, change.oldValue);
          case RestoreChangeKind.addToList:
          case RestoreChangeKind.replaceList:
            await writer.replaceList(
              change.category,
              change.oldValue is List ? change.oldValue as List : const [],
            );
          case RestoreChangeKind.replaceProfile:
            if (change.oldValue is Map) {
              await writer.replaceProfile(
                Map<String, dynamic>.from(change.oldValue as Map),
              );
            } else {
              await writer.replaceProfile(const {});
            }
          case RestoreChangeKind.replaceAiSettings:
            if (change.oldValue is Map) {
              await writer.setAiSettings(
                Map<String, dynamic>.from(change.oldValue as Map),
              );
            }
          case RestoreChangeKind.mergeProgress:
            await writer.mergeProgress(
              change.oldValue is Map
                  ? (change.oldValue as Map).map(
                      (key, value) => MapEntry(
                        key.toString(),
                        value is int ? value : 0,
                      ),
                    )
                  : <String, int>{},
            );
          case RestoreChangeKind.installFont:
            // The previous font file is not journaled in the first version;
            // the old family setting is restored by the caller if it exists.
            break;
        }
      } on Object catch (_) {
        complete = false;
      }
    }
    return complete;
  }

  static Map<String, dynamic> _changeToJson(RestoreChange change) => {
    'category': change.category,
    'key': change.key,
    'kind': change.kind.name,
    'old': change.oldValue,
    'new': change.newValue,
  };

  static RestoreChange? _changeFromJson(Map raw) {
    final category = raw['category'];
    final key = raw['key'];
    final kindName = raw['kind'];
    if (category is! String || key is! String || kindName is! String) {
      return null;
    }
    final kind = RestoreChangeKind.values.where((k) => k.name == kindName);
    if (kind.isEmpty) return null;
    return RestoreChange(
      category: category,
      key: key,
      kind: kind.first,
      oldValue: raw['old'],
      newValue: raw['new'],
    );
  }

  static bool _jsonEquals(Object? a, Object? b) =>
      jsonEncode(a) == jsonEncode(b);
}

enum RecoveryResult { none, completed, rolledBack, failed }
