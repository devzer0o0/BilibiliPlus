// ignore_for_file: prefer_interpolation_to_compose_strings, prefer_initializing_formals
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/models/ai_recommend/ai_recommend_settings.dart';
import 'package:PiliPlus/models/ai_recommend/interest_profile.dart';
import 'package:PiliPlus/models_new/history/data.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/ai_recommend/interest_profile_repository.dart';
import 'package:PiliPlus/utils/ai_recommend/interest_profile_service.dart';

typedef HistoryPageLoader = Future<LoadingState<HistoryData>> Function({
  required int max,
  required int viewAt,
});

class HistoryImportResult {
  const HistoryImportResult({
    this.scanned = 0,
    this.supported = 0,
    this.completed = 0,
    this.partial = 0,
    this.unknownProgress = 0,
    this.imported = 0,
    this.skipped = 0,
    this.message = '',
    this.failed = false,
  });

  const HistoryImportResult.error(String message)
    : scanned = 0,
      supported = 0,
      completed = 0,
      partial = 0,
      unknownProgress = 0,
      imported = 0,
      skipped = 0,
      message = message,
      failed = true;

  final int scanned;
  final int supported;
  final int completed;
  final int partial;
  final int unknownProgress;
  final int imported;
  final int skipped;
  final String message;
  final bool failed;

  String get summary {
    if (failed) return message;
    return '扫描 ' +
        scanned.toString() +
        ' 条，支持 ' +
        supported.toString() +
        ' 条（看完 ' +
        completed.toString() +
        '，部分 ' +
        partial.toString() +
        '），已学习 ' +
        imported.toString() +
        ' 条，跳过 ' +
        skipped.toString() +
        ' 条';
  }
}

/// Explicit, bounded history import. Defaults: 30 days, 200 entries, existing
/// UserHttp.historyList, cursor pagination, archive videos only.
///
/// It never sends the history to a model and never stores an exact playback
/// trace: each item becomes the same reduced WatchSignal that local playback
/// produces.
class HistoryImporter {
  HistoryImporter({
    this.days = 30,
    this.maxEntries = 200,
    this.pageSize = 20,
    HistoryPageLoader? loader,
    DateTime Function()? clock,
  }) : _loader =
           loader ??
           (({required max, required viewAt}) => UserHttp.historyList(
             type: 'archive',
             ps: pageSize,
             max: max,
             viewAt: viewAt,
             account: Accounts.history,
           )),
       _clock = clock ?? DateTime.now;

  final int days;
  final int maxEntries;
  final int pageSize;
  final HistoryPageLoader _loader;
  final DateTime Function() _clock;

  Future<HistoryImportResult> importRecent({
    required InterestProfileStore store,
    required AiRecommendSettings settings,
    required String accountScope,
  }) async {
    if (settings.pausedLearning) {
      return const HistoryImportResult.error('学习已暂停');
    }
    if (accountScope == AccountScope.anonymous) {
      return const HistoryImportResult.error('未登录，无法读取观看历史');
    }
    final now = _clock();
    final cutoff = now.subtract(Duration(days: days)).millisecondsSinceEpoch;
    final cutoffSeconds = cutoff ~/ 1000;

    var max = 0;
    var viewAt = 0;
    var scanned = 0;
    var supported = 0;
    var completed = 0;
    var partial = 0;
    var unknown = 0;
    var imported = 0;
    var skipped = 0;
    var failed = false;
    String? failure;

    var profile =
        await store.read(accountScope) ?? InterestProfile.empty(accountScope);

    for (var page = 0; page < 10 && scanned < maxEntries; page++) {
      final LoadingState<HistoryData> result;
      try {
        result = await _loader(max: max, viewAt: viewAt);
      } on Object catch (_) {
        failed = true;
        failure = '读取观看历史失败';
        break;
      }
      if (result is Error) {
        failed = true;
        failure = result.errMsg ?? '读取观看历史失败';
        break;
      }
      if (result is! Success<HistoryData>) break;
      final list = result.response.list;
      if (list == null || list.isEmpty) break;

      var pageNewest = viewAt;
      var reachedCutoff = false;
      for (final item in list) {
        if (scanned >= maxEntries) break;
        final itemViewAt = item.viewAt;
        if (itemViewAt == null) continue;
        if (itemViewAt > pageNewest) pageNewest = itemViewAt;
        if (itemViewAt < cutoffSeconds) {
          reachedCutoff = true;
          break;
        }
        scanned++;
        final business = item.history.business;
        if (business != null && business != 'archive') {
          skipped++;
          continue;
        }
        final duration = item.duration ?? 0;
        final progress = item.progress;
        if (duration <= 0 || progress == null || progress == 0) {
          unknown++;
          skipped++;
          continue;
        }
        supported++;
        final isCompleted = progress == -1 || progress >= duration - 2;
        final effectiveMs = isCompleted
            ? duration * 1000
            : progress.clamp(0, duration) * 1000;
        if (isCompleted) {
          completed++;
        } else {
          partial++;
        }
        final signal = WatchSignal(
          bvid: item.history.bvid ?? '',
          cid: item.history.cid,
          title: item.title ?? item.showTitle ?? '',
          ownerMid: item.authorMid,
          durationMs: duration * 1000,
          effectiveMs: effectiveMs,
          completed: isCompleted,
          at: now,
          backend: 'history-import',
          accountScope: accountScope,
        );
        if (!signal.isEligible || signal.bvid.isEmpty || signal.title.isEmpty) {
          skipped++;
          continue;
        }
        final next = InterestProfileService.applyWatch(
          profile,
          signal,
          settings,
          now: now,
        );
        if (!identical(next, profile) &&
            next.events.length > profile.events.length) {
          imported++;
          profile = next;
        } else {
          skipped++;
        }
      }

      if (imported > 0) await store.write(profile);
      if (reachedCutoff) break;

      final last = list.last;
      final nextMax = last.history.oid ?? 0;
      final nextViewAt = last.viewAt ?? 0;
      if (nextMax == max && nextViewAt == viewAt) break;
      max = nextMax;
      viewAt = nextViewAt;
      if (pageNewest < cutoffSeconds) break;
    }

    if (imported > 0) await store.write(profile);
    return HistoryImportResult(
      scanned: scanned,
      supported: supported,
      completed: completed,
      partial: partial,
      unknownProgress: unknown,
      imported: imported,
      skipped: skipped,
      failed: failed,
      message: failed ? (failure ?? '导入失败') : '',
    );
  }
}
