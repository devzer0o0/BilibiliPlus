import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/backend/playback_backend.dart';

/// Scriptable backend for tests.
///
/// Lets the session rules - generation filtering, intent survival across a
/// source change, ready-gated seek - be asserted without media_kit, a platform
/// view or a device.
class FakePlaybackBackend implements PlaybackBackend {
  FakePlaybackBackend({
    this.kind = PlaybackBackendKind.mpv,
    this.generation = 0,
    this.readyAfterOpen = true,
  });

  @override
  final PlaybackBackendKind kind;
  final int generation;
  final bool readyAfterOpen;

  final _controller = StreamController<PlaybackSnapshot>.broadcast();

  final List<String> calls = [];
  PlaybackRequest? request;
  bool disposed = false;

  PlaybackSnapshot _snapshot = const PlaybackSnapshot();

  @override
  PlaybackSnapshot get snapshot => _snapshot;

  @override
  Stream<PlaybackSnapshot> get snapshots => _controller.stream;

  void emit(PlaybackSnapshot snapshot) {
    if (_controller.isClosed) return;
    _snapshot = snapshot;
    _controller.add(snapshot);
  }

  @override
  Future<void> open(PlaybackRequest request) async {
    this.request = request;
    calls.add('open');
    if (!readyAfterOpen) return;
    emit(
      PlaybackSnapshot(
        generation: generation,
        backend: kind,
        ready: true,
        rate: request.rate,
      ),
    );
  }

  @override
  Future<void> play() async {
    calls.add('play');
    emit(_snapshot.copyWith(playing: true, completed: false));
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    emit(_snapshot.copyWith(playing: false));
  }

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek:${position.inMilliseconds}');
    emit(_snapshot.copyWith(position: position));
  }

  @override
  Future<void> setRate(double rate) async {
    calls.add('rate:$rate');
    emit(_snapshot.copyWith(rate: rate));
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    calls.add('dispose');
    if (!_controller.isClosed) await _controller.close();
  }
}
