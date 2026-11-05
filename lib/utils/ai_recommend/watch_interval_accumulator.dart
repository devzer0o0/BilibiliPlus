// ignore_for_file: cascade_invocations
import 'package:PiliPlus/models/ai_recommend/interest_profile.dart';

/// The subset of a playback event this feature needs. Pure so the interval
/// arithmetic can be tested without a player or a platform channel.
class WatchTick {
  const WatchTick({
    required this.positionMs,
    required this.durationMs,
    required this.playing,
    required this.buffering,
    required this.ready,
    required this.generation,
    this.completed = false,
    this.rate = 1.0,
    this.backend = 'unknown',
  });

  final int positionMs;
  final int durationMs;
  final bool playing;
  final bool buffering;
  final bool ready;
  final int generation;
  final bool completed;
  final double rate;
  final String backend;
}

class _Interval {
  _Interval(this.start, this.end);

  final int start;
  final int end;
}

/// Accumulates *effective* watching from a position/state stream.
///
/// Rules, each covered by a test:
///  * paused, buffering, unready or errored ticks credit nothing;
///  * a forward jump larger than the elapsed wall clock allows is a seek, not
///    watching, and credits nothing;
///  * a backward jump credits nothing;
///  * at 2x a 10-second wall gap covers 20 seconds of media but still counts as
///    10 seconds of the user's time;
///  * overlapping and repeated intervals are merged, so replaying the same
///    minute does not inflate coverage;
///  * a generation change (quality/source switch) resets the clock but keeps
///    already-credited intervals for the same video context.
class WatchIntervalAccumulator {
  WatchIntervalAccumulator({
    this.maxWallGapMs = 3000,
    this.seekToleranceMs = 1500,
  });

  final int maxWallGapMs;
  final int seekToleranceMs;

  final List<_Interval> _intervals = [];
  int _effectiveMs = 0;
  int _lastPositionMs = 0;
  int _lastWallMs = 0;
  int _lastGeneration = 0;
  double _lastRate = 1;
  bool _hasLast = false;
  bool _completed = false;

  int get effectiveMs => _effectiveMs;

  int get mediaCoveredMs {
    var total = 0;
    for (final interval in _intervals) {
      total += interval.end - interval.start;
    }
    return total;
  }

  double coverage(int durationMs) =>
      durationMs <= 0 ? 0 : (mediaCoveredMs / durationMs).clamp(0.0, 1.0);

  bool get completed => _completed;

  void reset() {
    _intervals.clear();
    _effectiveMs = 0;
    _lastPositionMs = 0;
    _lastWallMs = 0;
    _lastGeneration = 0;
    _lastRate = 1;
    _hasLast = false;
    _completed = false;
  }

  void onTick(WatchTick tick, int wallMs) {
    if (tick.completed) _completed = true;
    if (tick.durationMs > 0 && tick.positionMs >= tick.durationMs - 1500) {
      _completed = true;
    }

    final usable =
        tick.ready &&
        tick.playing &&
        !tick.buffering &&
        tick.rate > 0 &&
        tick.positionMs >= 0;
    if (!usable) {
      _hasLast = false;
      return;
    }

    if (!_hasLast || tick.generation != _lastGeneration) {
      _hasLast = true;
      _lastPositionMs = tick.positionMs;
      _lastWallMs = wallMs;
      _lastGeneration = tick.generation;
      _lastRate = tick.rate;
      return;
    }

    final wallDelta = wallMs - _lastWallMs;
    final posDelta = tick.positionMs - _lastPositionMs;
    final rate = tick.rate;
    final previousRate = _lastRate;
    _lastPositionMs = tick.positionMs;
    _lastWallMs = wallMs;
    _lastGeneration = tick.generation;
    _lastRate = rate;

    if (wallDelta <= 0 || wallDelta > maxWallGapMs) return;
    if (posDelta < -500) return;
    if (posDelta <= 0) return;

    // What the media clock should have advanced if this was real playback.
    final expected = wallDelta * ((rate + previousRate) / 2);
    if (posDelta > expected + seekToleranceMs) return;

    // Credit wall time, not media time: at 2x, one second on the wall is one
    // second of the user's attention even though the position moved two.
    final mediaDelta = posDelta;
    final watchedMs = (wallDelta * (mediaDelta / expected)).round().clamp(
      0,
      wallDelta,
    );
    if (watchedMs <= 0) return;
    _effectiveMs += watchedMs;
    _addInterval(_lastPositionMs - mediaDelta, _lastPositionMs);
  }

  void _addInterval(int start, int end) {
    if (end <= start) return;
    final merged = <_Interval>[];
    var next = _Interval(start, end);
    for (final interval in _intervals) {
      if (interval.end + 500 < next.start || next.end + 500 < interval.start) {
        merged.add(interval);
      } else {
        next = _Interval(
          interval.start < next.start ? interval.start : next.start,
          interval.end > next.end ? interval.end : next.end,
        );
      }
    }
    merged.add(next);
    merged.sort((a, b) => a.start.compareTo(b.start));
    _intervals
      ..clear()
      ..addAll(merged);
  }

  WatchSignal? buildSignal({
    required String bvid,
    required String title,
    required int durationMs,
    required DateTime at,
    required String accountScope,
    int? cid,
    int? ownerMid,
    String backend = 'unknown',
  }) {
    if (bvid.isEmpty || durationMs <= 0 || _effectiveMs <= 0) return null;
    return WatchSignal(
      bvid: bvid,
      cid: cid,
      title: title,
      ownerMid: ownerMid,
      durationMs: durationMs,
      effectiveMs: _effectiveMs,
      completed: _completed,
      at: at,
      backend: backend,
      accountScope: accountScope,
    );
  }
}
