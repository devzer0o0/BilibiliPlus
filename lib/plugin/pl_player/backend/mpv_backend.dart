import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/backend/playback_backend.dart';
import 'package:media_kit/media_kit.dart';

/// The existing mpv path, expressed through the backend contract.
///
/// Opening the media stays with the caller ([openMedia]) because the mpv
/// options, EDL assembly and audio-follow toggles already live there; what this
/// adapter owns is the rule that mpv reports through one snapshot stream and
/// stops when the session swaps it out.
class MpvPlaybackBackend implements PlaybackBackend {
  MpvPlaybackBackend({
    required Player mediaPlayer,
    required int sourceGeneration,
    required Future<void> Function(PlaybackRequest request) mediaOpener,
    Map<String, String>? mpvOptions,
  }) : _player = mediaPlayer,
       _generation = sourceGeneration,
       _openMedia = mediaOpener,
       _extraOptions = mpvOptions;

  final Player _player;
  final int _generation;
  final Future<void> Function(PlaybackRequest request) _openMedia;

  final Map<String, String>? _extraOptions;

  final _controller = StreamController<PlaybackSnapshot>.broadcast();
  final List<StreamSubscription> _subs = [];

  PlaybackSnapshot _snapshot = const PlaybackSnapshot();
  bool _disposed = false;

  @override
  PlaybackBackendKind get kind => PlaybackBackendKind.mpv;

  @override
  Stream<PlaybackSnapshot> get snapshots => _controller.stream;

  @override
  PlaybackSnapshot get snapshot => _snapshot;

  Map<String, String>? get extraOptions => _extraOptions;

  void _attach() {
    if (_subs.isNotEmpty) return;
    final stream = _player.stream;
    _subs.addAll([
      stream.playing.listen((playing) {
        _update(playing: playing, completed: false);
      }),
      stream.completed.listen((completed) {
        if (completed) _update(completed: true, playing: false);
      }),
      stream.position.listen((position) {
        final pos = _clamp(position);
        if (pos != _snapshot.position) _update(position: pos, ready: true);
      }),
      stream.duration.listen((duration) {
        if (duration > Duration.zero) _update(duration: duration, ready: true);
      }),
      stream.buffer.listen((buffer) {
        if (buffer != _snapshot.buffered) _update(buffered: buffer);
      }),
      stream.buffering.listen((buffering) {
        _update(buffering: buffering, ready: true);
      }),
    ]);
  }

  Duration _clamp(Duration position) {
    final duration = _snapshot.duration;
    if (duration <= Duration.zero) return position;
    return position > duration ? duration : position;
  }

  void _update({
    Duration? position,
    Duration? duration,
    Duration? buffered,
    bool? playing,
    bool? buffering,
    bool? completed,
    bool? ready,
    double? rate,
    String? error,
  }) {
    if (_disposed) return;
    _snapshot = _snapshot.copyWith(
      generation: _generation,
      backend: PlaybackBackendKind.mpv,
      position: position,
      duration: duration,
      buffered: buffered,
      playing: playing,
      buffering: buffering,
      completed: completed,
      ready: ready,
      rate: rate,
      error: error,
    );
    if (!_controller.isClosed) _controller.add(_snapshot);
  }

  @override
  Future<void> open(PlaybackRequest request) async {
    _attach();
    await _openMedia(request);
    _update(ready: true, rate: request.rate);
    if (request.rate != 1.0) await _player.setRate(request.rate);
    if (request.autoPlay) await _player.play();
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(_clamp(position));

  @override
  Future<void> setRate(double rate) async {
    await _player.setRate(rate);
    _update(rate: rate);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    if (!_controller.isClosed) await _controller.close();
  }
}
