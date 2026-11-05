import 'dart:async';

import 'package:PiliPlus/utils/backup/backup_service.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';

/// Foreground-opportunity scheduler. It never promises iOS background delivery:
/// it runs on app start/resume, connectivity recovery and after settings stop
/// changing for 30 seconds.
class BackupScheduler with WidgetsBindingObserver {
  BackupScheduler._();

  static final BackupScheduler instance = BackupScheduler._();

  final BackupService _service = BackupService.instance;
  Timer? _debounce;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  final List<StreamSubscription<dynamic>> _boxSubscriptions = [];
  bool _started = false;
  bool _checking = false;

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _boxSubscriptions.addAll([
      GStorage.setting.watch().listen((_) => _onSettingsChanged()),
      GStorage.video.watch().listen((_) => _onSettingsChanged()),
      GStorage.localCache.watch().listen((_) => _onSettingsChanged()),
    ]);
    _connectivity = Connectivity().onConnectivityChanged.listen((results) {
      if (_hasNetwork(results)) unawaited(_trigger('network'));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_trigger('startup'));
    });
  }

  void stop() {
    _started = false;
    _debounce?.cancel();
    _connectivity?.cancel();
    for (final subscription in _boxSubscriptions) {
      subscription.cancel();
    }
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_trigger('resume'));
    }
  }

  void _onSettingsChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 30), () {
      unawaited(_trigger('settings'));
    });
  }

  Future<void> _trigger(String reason) async {
    if (_checking || _service.isRunning || _service.isRestoring) return;
    final config = _service.config;
    if (!config.autoEnabled) return;
    if (config.validationError() != null) return;
    if (!await _service.hasCredentials()) return;
    if (await _service.recoveryKeyId() == null) return;

    final last = _service.repository.lastAutoAt;
    if (last != null &&
        DateTime.now().toUtc().difference(last.toUtc()) <
            Duration(hours: config.autoIntervalHours)) {
      return;
    }

    _checking = true;
    try {
      if (config.autoWifiOnly) {
        final results = await Connectivity().checkConnectivity();
        if (!_hasWifi(results)) {
          _service.markAttention('等待 Wi-Fi 后自动备份');
          return;
        }
      } else {
        final results = await Connectivity().checkConnectivity();
        if (!_hasNetwork(results)) {
          _service.markAttention('等待网络后自动备份');
          return;
        }
      }
      final draft = await _service.buildDraft();
      if (_service.repository.baselineHash == draft.contentFingerprint) {
        return;
      }
      await _service.backupNow(auto: true);
    } on Object catch (_) {
      // The service records a user-facing failure; a background opportunity
      // must not produce an unhandled error.
    } finally {
      _checking = false;
    }
  }

  static bool _hasNetwork(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);

  static bool _hasWifi(List<ConnectivityResult> results) =>
      results.contains(ConnectivityResult.wifi) ||
      results.contains(ConnectivityResult.ethernet);
}
