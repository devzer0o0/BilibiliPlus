import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/backend/playback_backend.dart';

/// Owns exactly one active backend and the user intent that outlives it.
///
/// Everything the UI sees comes out of [events], stamped with the generation
/// of the source it belongs to. Two rules make the old failures impossible:
///
///  * an event from a superseded generation is dropped, so a slow backend
///    cannot paint its position over a newer source;
///  * play/pause/seek/rate are *intent*, re-applied when the new source
///    becomes ready, so a pause during preparation is not undone by a backend
///    that plays as soon as it can.
class PlaybackSession {
  PlaybackSession() {
    _events = StreamController<PlaybackSnapshot>.broadcast();
  }

  late final StreamController<PlaybackSnapshot> _events;

  /// Current source generation. Incremented per source change, never per seek.
  int _generation = 0;
  int get generation => _generation;

  PlaybackBackend? _backend;
  PlaybackBackendKind _kind = PlaybackBackendKind.none;
  PlaybackBackendKind get activeKind => _kind;

  StreamSubscription<PlaybackSnapshot>? _subscription;

  PlaybackSnapshot _latest = const PlaybackSnapshot();
  PlaybackSnapshot get snapshot => _latest;

  /// Latest position the user asked for. Applied on ready and cleared once the
  /// backend reports a position that satisfies it.
  Duration? _pendingSeek;

  double? _pendingRate;
  bool _desiredPlaying = false;
  bool _playApplied = true;
  bool _disposed = false;

  Stream<PlaybackSnapshot> get events => _events.stream;

  /// Swaps in [backend] for [request].
  ///
  /// The previous backend is disposed before the new one is opened: two
  /// players that both decode and both output audio is the bug being fixed,
  /// not a way to make switching feel faster.
  Future<void> open(PlaybackBackend backend, PlaybackRequest request) async {
    if (_disposed) return;
    final previous = _backend;
    await _subscription?.cancel();
    _subscription = null;
    _backend = null;
    if (previous != null && !identical(previous, backend)) {
      await previous.dispose();
    }

    _generation += 1;
    _kind = backend.kind;
    _backend = backend;
    _latest = PlaybackSnapshot(
      generation: _generation,
      backend: backend.kind,
      position: request.startPosition ?? Duration.zero,
      rate: request.rate,
    );
    _pendingSeek = request.startPosition;
    _pendingRate = request.rate;
    _desiredPlaying = request.autoPlay;
    _playApplied = false;

    _subscription = backend.snapshots.listen(_onEvent);
    await backend.open(request);
  }

  void _onEvent(PlaybackSnapshot event) {
    if (_disposed) return;
    // A stale backend, or one whose open raced a newer source, still emits.
    if (event.generation != 0 && event.generation != _generation) return;
    final merged = event.copyWith(
      generation: _generation,
      backend: _kind,
      // Never let a backend clear a duration it already reported for the same
      // source: several of them report zero until the index is parsed.
      duration: event.hasDuration ? event.duration : _latest.duration,
    );
    _latest = merged;
    _emit(merged);
    _reconcile(merged);
  }

  void _reconcile(PlaybackSnapshot snapshot) {
    final backend = _backend;
    if (backend == null || !snapshot.ready || snapshot.hasError) return;

    if (_pendingSeek case final target?) {
      final settled = (snapshot.position - target).abs() <=
          const Duration(milliseconds: 500);
      if (!settled) {
        _pendingSeek = null;
        _applySeek(backend, target);
        return;
      }
      _pendingSeek = null;
    }

    if (_pendingRate case final rate? when snapshot.rate != rate) {
      _pendingRate = null;
      _unawaited(backend.setRate(rate));
    }

    if (!_playApplied && !_desiredPlaying && snapshot.playing) {
      // A backend that started itself after the user paused it.
      _playApplied = true;
      _unawaited(backend.pause());
      return;
    }
    if (!_playApplied && _desiredPlaying && !snapshot.playing &&
        !snapshot.completed && !snapshot.buffering) {
      _playApplied = true;
      _unawaited(backend.play());
    }
  }

  void _applySeek(PlaybackBackend backend, Duration target) {
    _unawaited(backend.seek(target));
  }

  Future<void> play() async {
    if (_disposed) return;
    _desiredPlaying = true;
    _playApplied = false;
    final backend = _backend;
    if (backend != null && _latest.ready) {
      _playApplied = true;
      await backend.play();
    }
  }

  Future<void> pause() async {
    if (_disposed) return;
    _desiredPlaying = false;
    _playApplied = false;
    final backend = _backend;
    if (backend != null) {
      _playApplied = true;
      await backend.pause();
    }
  }

  Future<void> seek(Duration position) async {
    if (_disposed) return;
    final clamped = position < Duration.zero ? Duration.zero : position;
    final backend = _backend;
    if (backend == null) {
      _pendingSeek = clamped;
      return;
    }
    if (!_latest.ready) {
      // Remembered, not dropped: the newest intent wins when the source opens.
      _pendingSeek = clamped;
      return;
    }
    _pendingSeek = null;
    await backend.seek(clamped);
  }

  Future<void> setRate(double rate) async {
    if (_disposed) return;
    _pendingRate = rate;
    final backend = _backend;
    if (backend == null) return;
    if (!_latest.ready) return;
    _pendingRate = null;
    await backend.setRate(rate);
  }

  /// Whether a source is open at all.
  bool get hasSource => _backend != null;

  void _emit(PlaybackSnapshot snapshot) {
    if (!_events.isClosed) _events.add(snapshot);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription?.cancel();
    final backend = _backend;
    _backend = null;
    _kind = PlaybackBackendKind.none;
    if (backend != null) await backend.dispose();
    await _events.close();
  }

  static void _unawaited(Future<void> future) {
    future.catchError((Object _) {});
  }
}
