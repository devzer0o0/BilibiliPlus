import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/backend/playback_backend.dart';
import 'package:flutter/services.dart';

/// The AVPlayer/AVPlayerLayer path on iOS.
///
/// The native side owns one `AVPlayer` per session, so audio and video share a
/// single system clock. State arrives on an event channel for as long as the
/// session lives; there is no fixed number of polls after which updates stop.
class NativePlaybackBackend implements PlaybackBackend {
  NativePlaybackBackend({
    required this.sessionId,
    required this.generation,
    MethodChannel? control,
    EventChannel? events,
  }) : _control = control ?? const MethodChannel(controlChannel),
       _events = events ?? const EventChannel(eventChannel);

  static const controlChannel = 'pilipilus/hdr_video/control';
  static const eventChannel = 'pilipilus/hdr_video/events';

  final String sessionId;
  final int generation;
  final MethodChannel _control;
  final EventChannel _events;

  final _controller = StreamController<PlaybackSnapshot>.broadcast();
  StreamSubscription? _eventsSub;

  PlaybackSnapshot _snapshot = const PlaybackSnapshot(
    backend: PlaybackBackendKind.native,
  );
  bool _disposed = false;

  @override
  PlaybackBackendKind get kind => PlaybackBackendKind.native;

  @override
  PlaybackSnapshot get snapshot => _snapshot;

  @override
  Stream<PlaybackSnapshot> get snapshots => _controller.stream;

  Future<void> _invoke(String method, [Map<String, Object?> args = const {}]) {
    return _control.invokeMethod<void>(method, {
      'sessionId': sessionId,
      ...args,
    });
  }

  /// Native map -> snapshot. [PlaybackSnapshot.position] is the only clock the
  /// UI reads; seconds from AVPlayer are converted exactly once, here.
  static PlaybackSnapshot parse(Map<Object?, Object?> map, int generation) {
    double seconds(Object? v) => (v as num?)?.toDouble() ?? 0;
    final duration = seconds(map['duration']);
    final rate = (map['rate'] as num?)?.toDouble() ?? 0;
    return PlaybackSnapshot(
      generation: generation,
      backend: PlaybackBackendKind.native,
      position: Duration(milliseconds: (seconds(map['seconds']) * 1000).round()),
      duration: duration.isFinite && duration > 0
          ? Duration(milliseconds: (duration * 1000).round())
          : Duration.zero,
      buffered: Duration.zero,
      playing: rate != 0,
      buffering: map['timeControl'] == 1,
      ready: map['ready'] == true,
      completed: map['completed'] == true,
      rate: rate,
      error: map['error'] as String?,
    );
  }

  void _onEvent(Object? raw) {
    if (_disposed || raw is! Map) return;
    if (raw['sessionId'] != sessionId) return;
    if (raw['event'] == 'state' && raw['state'] is Map) {
      final next = parse(raw['state'] as Map, generation);
      _snapshot = next;
      if (!_controller.isClosed) _controller.add(next);
    } else if (raw['event'] == 'error') {
      final next = _snapshot.copyWith(
        error: raw['message'] as String? ?? 'native playback failed',
      );
      _snapshot = next;
      if (!_controller.isClosed) _controller.add(next);
    }
  }

  /// What the native side needs to describe the source without guessing.
  ///
  /// The ranges come from the playurl response; the codec, size and frame rate
  /// must match the init segment's sample entry, or AVFoundation parses the
  /// playlist and then fails on the first fragment.
  Map<String, Object?> _describeRequest(PlaybackRequest request) => {
    'video': request.videoSegmentBase?.toMap() ?? const <String, Object?>{},
    'audio': request.audioSegmentBase?.toMap() ?? const <String, Object?>{},
    'videoCodecs': ?request.videoCodecs,
    'audioCodecs': ?request.audioCodecs,
    'width': ?request.width,
    'height': ?request.height,
    'frameRate': ?request.frameRate,
  };

  @override
  Future<void> open(PlaybackRequest request) async {
    _eventsSub ??= _events.receiveBroadcastStream().listen(_onEvent);
    await _invoke('createSession', {
      ..._describeRequest(request),
      'url': request.videoUrl,
      'audioUrl': request.audioUrl,
      'startMs': request.startPosition?.inMilliseconds ?? 0,
      'autoPlay': request.autoPlay,
      'rate': request.rate,
      'sourceKey': request.sourceKey,
    });
  }

  /// Replaces the media on the existing session instead of recreating the
  /// surface, so a quality change cannot be mistaken for a new page.
  Future<void> replaceSource(PlaybackRequest request) => _invoke(
    'replaceSource',
    {
      ..._describeRequest(request),
      'url': request.videoUrl,
      'audioUrl': request.audioUrl,
      'startMs': request.startPosition?.inMilliseconds ?? 0,
      'autoPlay': request.autoPlay,
      'rate': request.rate,
      'sourceKey': request.sourceKey,
    },
  );

  @override
  Future<void> play() => _invoke('play');

  @override
  Future<void> pause() => _invoke('pause');

  @override
  Future<void> seek(Duration position) =>
      _invoke('seek', {'ms': position.inMilliseconds});

  @override
  Future<void> setRate(double rate) => _invoke('setRate', {'rate': rate});

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _invoke('dispose');
    } catch (_) {
      // The session may already be gone after a native crash; nothing to do.
    }
    await _eventsSub?.cancel();
    _eventsSub = null;
    if (!_controller.isClosed) await _controller.close();
  }
}
