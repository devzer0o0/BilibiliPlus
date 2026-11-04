import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/backend/native_backend.dart';
import 'package:PiliPlus/plugin/pl_player/backend/playback_backend.dart';
import 'package:PiliPlus/plugin/pl_player/backend/playback_session.dart';

/// Owns the native `PlaybackSession` for the facade.
///
/// This is the production seam between [PlaybackSession] and the controller:
/// the controller allocates one generation per media switch, hands it here, and
/// only snapshots that carry that exact generation are forwarded. An event from
/// a superseded session is dropped instead of being relabelled, and the first
/// open is no longer filtered out because two counters disagreed.
class NativeSessionHost {
  NativeSessionHost({this.onSnapshot, this.backendFor});

  /// Receives already-validated snapshots. The controller reduces them into its
  /// own state; nothing else is allowed to read the session directly.
  final void Function(PlaybackSnapshot snapshot)? onSnapshot;

  /// Test seam for the platform channels. Production leaves it null and gets a
  /// real [NativePlaybackBackend].
  final PlaybackBackend Function(int generation, String sessionId)? backendFor;

  PlaybackSession? _session;
  PlaybackBackend? _backend;
  StreamSubscription<PlaybackSnapshot>? _subscription;

  /// Backend handed to the session by the newest open. Test-visible.
  PlaybackBackend? get backend => _backend;
  int _openedGeneration = 0;
  String? _openedSessionId;

  /// Generation of the newest open, or 0 before the first one.
  int get openedGeneration => _openedGeneration;

  /// Session id of the newest open, or null.
  String? get openedSessionId => _openedSessionId;

  PlaybackSession? get session => _session;

  /// True once a backend has been opened and not yet torn down.
  bool get isOpen => _session?.hasSource ?? false;

  Future<void> open({
    required int generation,
    required String sessionId,
    required PlaybackRequest request,
  }) async {
    final session = _session ??= PlaybackSession();
    _openedGeneration = generation;
    _openedSessionId = sessionId;
    await _subscription?.cancel();
    _subscription = session.events.listen(_onEvent);
    final backend =
        backendFor?.call(generation, sessionId) ??
        NativePlaybackBackend(sessionId: sessionId, generation: generation);
    _backend = backend;
    await session.open(backend, request, generation: generation);
  }

  void _onEvent(PlaybackSnapshot snapshot) {
    // Strict identity: the event must be the one this host opened. Relabelling
    // is what let a stalled backend paint over a newer source.
    if (snapshot.generation != _openedGeneration) return;
    onSnapshot?.call(snapshot);
  }

  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    final session = _session;
    _session = null;
    _openedSessionId = null;
    await session?.dispose();
  }

  /// Disposes the session for good. Used from the controller's dispose.
  Future<void> dispose() => close();
}
