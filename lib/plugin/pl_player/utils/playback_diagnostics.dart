import 'dart:async';
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
/// Every entry is gated on [enabled]: a debug or profile build, never a release.
/// Bounded by line caps and rate limits, and URLs are stripped, so no signed
/// link or credential can end up in it.
///
/// Writes are buffered and drained by a timer, never inline on the thread that
/// produced them. libmpv's own log - the only place a decoder explains itself -
/// arrives at video frame rate, and a synchronous file write per line there is
/// a way to cause the stutter the log was opened to explain.
abstract final class PlaybackDiagnostics {
  /// Off in a release build. A shipping app writes nothing here.
  static const bool enabled = !bool.fromEnvironment('dart.vm.product');

  /// Milestone and sample lines. Past this, only [_alwaysKept] tags get in.
  static const int _limit = 600;

  /// Lines the verbatim libmpv trace may add on top of [_limit].
  static const int _traceLimit = 900;

  /// Rate limit for repetitive sampling only.
  ///
  /// A milestone must never be dropped: the first version applied this to every
  /// line and lost the `native-open` record that immediately followed `route`,
  /// which is exactly the line needed to tell "never opened" from "opened and
  /// never became ready".
  static const Duration _sampleInterval = Duration(milliseconds: 500);

  /// How often buffered lines reach the disk.
  ///
  /// Long enough that the write is amortised over many lines, short enough that
  /// a crash still leaves the seconds before it on disk.
  static const Duration _flushInterval = Duration(milliseconds: 700);

  static File? _file;
  static int _lines = 0;
  static int _traceLines = 0;
  static DateTime? _last;
  static final StringBuffer _pending = StringBuffer();
  static Timer? _flushTimer;
  static bool _flushing = false;

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
      _pending.clear();
      file.writeAsStringSync('', flush: true);
      _lines = 0;
      _traceLines = 0;
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
    if (_lines >= _limit && !_alwaysKept.contains(tag)) return;
    _lines++;
    _append(now, tag, message);
  }

  /// Diagnostic tags that must never be rate limited.
  ///
  /// A burst of them lands in the same millisecond; dropping all but the first
  /// is how a six-message sample turned into three identical lines.
  static const _unsampled = {'share-msg', 'share-session', 'share'};

  /// Tags allowed past [_limit].
  ///
  /// The cap protects the disk from a runaway loop, but a chatty tag must not
  /// be able to starve the measurements a diagnostic build exists to collect:
  /// measured once, per-item share logging filled 527 of 600 lines and every
  /// `decoder` sample was dropped, so the log looked like "playback is fine".
  static const _alwaysKept = {'decoder', 'decoder-software', 'mpv-log'};

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

  /// A line from libmpv's own log, kept verbatim.
  ///
  /// Separate from [sample] on purpose: a decoder's explanation of a fallback is
  /// one line among hundreds, so rate limiting by arrival time drops exactly the
  /// line that matters. It gets its own budget instead, and it never increments
  /// [_lines] - otherwise the trace would evict the measurements.
  static void trace(String tag, String message) {
    if (!enabled) return;
    if (_traceLines >= _traceLimit) return;
    _traceLines++;
    _append(DateTime.now(), tag, message);
  }

  static void _append(DateTime at, String tag, String message) {
    try {
      if (_target == null) return;
      _pending.write('${at.toIso8601String()} $tag ${_redact(message)}\n');
      _flushTimer ??= Timer.periodic(_flushInterval, (_) => flush());
    } catch (_) {
      // Never let logging break playback.
    }
  }

  /// Writes everything buffered so far.
  ///
  /// Asynchronous, and re-entrancy is guarded: the timer fires again while a
  /// previous write is still in flight, and two overlapping appends would
  /// interleave. A failure drops the buffer rather than retrying forever.
  static Future<void> flush() async {
    if (!enabled || _flushing) return;
    final file = _target;
    if (file == null || _pending.isEmpty) return;
    _flushing = true;
    final chunk = _pending.toString();
    _pending.clear();
    try {
      await file.writeAsString(chunk, mode: FileMode.append, flush: true);
    } catch (_) {
      // Same: never let logging break playback.
    } finally {
      _flushing = false;
    }
  }

  /// Drops anything that looks like a signed URL or a credential.
  static String _redact(String value) {
    final noQuery = value.replaceAll(RegExp(r'https?://\S+'), '<url>');
    return noQuery.length <= 300 ? noQuery : '${noQuery.substring(0, 300)}...';
  }
}
