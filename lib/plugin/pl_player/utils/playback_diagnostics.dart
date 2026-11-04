import 'dart:io';

import 'package:PiliPlus/utils/path_utils.dart';

/// Records playback facts the UI never shows.
///
/// A 4K stream that stalls leaves the screen on 加载中 and the log with nothing
/// in it: the app only reports errors it decides to surface. Diagnostics that
/// answer "why did it not start" have to be written where they can be read back
/// afterwards, which is a file in the app container - `idevicesyslog` needs its
/// own device channel and is not always available.
///
/// Every write is gated on [enabled]: a debug/profile build, never a release.
/// Bounded by a line cap and rate limit, and the session id is truncated, so no
/// URL, header or token can end up in it.
abstract final class PlaybackDiagnostics {
  /// Off in a release build. A shipping app writes nothing here.
  static const bool enabled = !bool.fromEnvironment('dart.vm.product');

  static const int _limit = 600;

  /// Rate limit for repetitive sampling only.
  ///
  /// A milestone must never be dropped: the first version applied this to every
  /// line and lost the `native-open` record that immediately followed `route`,
  /// which is exactly the line needed to tell "never opened" from "opened and
  /// never became ready".
  static const Duration _sampleInterval = Duration(milliseconds: 500);

  static File? _file;
  static int _lines = 0;
  static DateTime? _last;

  static File? get _target {
    if (!enabled) return null;
    return _file ??= File('$appSupportDirPath/playback_diag.log');
  }

  /// Starts a new record for a session, truncating the previous one.
  static void begin(String tag) {
    if (!enabled) return;
    try {
      final file = _target;
      if (file == null) return;
      file.writeAsStringSync('', flush: true);
      _lines = 0;
      _last = null;
      record('session', tag);
    } catch (_) {
      // Diagnostics must never be the reason playback fails.
    }
  }

  /// Appends one line. Milestones are never rate limited; only [sample] is.
  static void record(String tag, String message) {
    if (!enabled) return;
    final now = DateTime.now();
    _last = now;
    try {
      final file = _target;
      if (file == null || _lines >= _limit) return;
      _lines++;
      final line =
          '${now.toIso8601String()} $tag ${_redact(message)}\n';
      file.writeAsStringSync(line, mode: FileMode.append, flush: true);
    } catch (_) {
      // Same: never let logging break playback.
    }
  }

  /// Diagnostic tags that must never be rate limited.
  ///
  /// A burst of them lands in the same millisecond; dropping all but the first
  /// is how a six-message sample turned into three identical lines.
  static const _unsampled = {'share-msg', 'share-session', 'share'};

  /// High-frequency sampling, rate limited so a burst cannot fill the disk.
  static void sample(String tag, String message) {
    if (_unsampled.contains(tag)) {
      record(tag, message);
      return;
    }
    if (!enabled) return;
    final now = DateTime.now();
    final last = _last;
    if (last != null && now.difference(last) < _sampleInterval) return;
    record(tag, message);
  }

  /// Drops anything that looks like a signed URL or a credential.
  static String _redact(String value) {
    final noQuery = value.replaceAll(RegExp(r'https?://\S+'), '<url>');
    return noQuery.length <= 300 ? noQuery : '${noQuery.substring(0, 300)}...';
  }
}
