import 'package:flutter/foundation.dart';

/// Which player is actually producing the picture and the sound.
///
/// Exactly one backend is active in a session; the others are stopped. Hiding
/// or muting the loser is not exclusive playback - it keeps its decoder, its
/// audio output and its network requests alive.
enum PlaybackBackendKind { none, mpv, native }

/// One complete source, as the backend needs to open it.
///
/// Immutable on purpose: a source change is a new object with a new
/// [sourceKey], not a mutation of the current one. Rotation, full screen and
/// control-bar changes never produce a new request, so they cannot be mistaken
/// for a media change.
@immutable
class PlaybackRequest {
  const PlaybackRequest({
    required this.sourceKey,
    required this.videoUrl,
    this.audioUrl,
    this.startPosition,
    this.autoPlay = true,
    this.rate = 1.0,
    this.isLive = false,
    this.videoSegmentBase,
    this.audioSegmentBase,
    this.videoCodecs,
    this.width,
    this.height,
    this.frameRate,
    this.audioCodecs,
    this.quality,
  });

  /// Stable identity of the rendition, e.g. `bvid:cid:qn:codec`.
  final String sourceKey;

  /// Byte ranges the playurl response declared for this rendition.
  final SegmentBaseRange? videoSegmentBase;
  final SegmentBaseRange? audioSegmentBase;

  /// What the rendition actually is. The master playlist has to declare the
  /// same codec as the init segment: a hardcoded `hvc1` beside an `avc1`
  /// sample entry is rejected by the format reader after the first fragment.
  final String? videoCodecs;
  final int? width;
  final int? height;
  final String? frameRate;
  final String? audioCodecs;

  /// The catalogue's quality id for this rendition.
  ///
  /// Carried because it is the only trustworthy statement about dynamic range
  /// when the init segment has no `colr` box: the HDR rungs are the ones the
  /// catalogue labels as HDR. Bit depth is not that statement - a 10-bit SDR
  /// stream is still SDR - and using it as one made the native path declare PQ
  /// for media that never claimed it.
  final int? quality;

  final String videoUrl;

  /// Separate DASH audio track, when the service serves one.
  final String? audioUrl;

  /// Where playback should begin. The controller resolves the initial
  /// position (resume, default part start, skip intro) before creating this.
  final Duration? startPosition;

  /// The user's play/pause intent at open time. A backend must not play when
  /// this is false, not even after it becomes ready.
  final bool autoPlay;

  final double rate;
  final bool isLive;

  @override
  String toString() =>
      'PlaybackRequest($sourceKey start=$startPosition autoPlay=$autoPlay rate=$rate)';
}

/// `SegmentBase` from the playurl response: `"0-999"` and `"1000-1259"`.
///
/// The server already said where the initialization segment and the index are.
/// Re-discovering them on the client can only disagree with it.
@immutable
class SegmentBaseRange {
  const SegmentBaseRange({required this.initialization, required this.index});

  final String initialization;
  final String index;

  bool get isValid => initialization.isNotEmpty && index.isNotEmpty;

  Map<String, Object?> toMap() => {'init': initialization, 'index': index};

  /// Parses bilibili's `{Initialization: "0-999", indexRange: "1000-1259"}`.
  static SegmentBaseRange? fromJson(Map? json) {
    if (json == null) return null;
    final init = (json['Initialization'] ?? json['initialization']) as String?;
    final index = (json['indexRange'] ?? json['index_range']) as String?;
    if (init == null || index == null) return null;
    final range = SegmentBaseRange(initialization: init, index: index);
    return range.isValid ? range : null;
  }
}

/// The only thing the UI is allowed to read from a backend.
///
/// [position] and [duration] are always the same instant from the same source,
/// so `positionInMilliseconds` can never disagree with `position`. The legacy
/// integer-second fields on the controller are derived from this one object.
@immutable
class PlaybackSnapshot {
  const PlaybackSnapshot({
    this.generation = 0,
    this.backend = PlaybackBackendKind.none,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.buffered = Duration.zero,
    this.playing = false,
    this.buffering = false,
    this.ready = false,
    this.completed = false,
    this.rate = 1.0,
    this.error,
  });

  /// Bumped on every source change. Events carrying an older generation are
  /// dropped by the session, so a slow backend cannot paint stale state over a
  /// newer source.
  final int generation;
  final PlaybackBackendKind backend;

  final Duration position;

  /// [Duration.zero] means "not known yet"; live streams may never report one.
  final Duration duration;
  final Duration buffered;

  final bool playing;
  final bool buffering;

  /// The source is prepared enough to render; position may still be zero.
  final bool ready;

  /// Played to the end. Not the same as paused: repeat/next depend on it.
  final bool completed;

  final double rate;

  /// Set when the backend failed for a reason the user has to act on.
  final String? error;

  int get positionInMilliseconds => position.inMilliseconds;
  int get durationInMilliseconds => duration.inMilliseconds;
  bool get hasDuration => duration > Duration.zero;
  bool get hasError => error != null;

  PlaybackSnapshot copyWith({
    int? generation,
    PlaybackBackendKind? backend,
    Duration? position,
    Duration? duration,
    Duration? buffered,
    bool? playing,
    bool? buffering,
    bool? ready,
    bool? completed,
    double? rate,
    String? error,
  }) => PlaybackSnapshot(
    generation: generation ?? this.generation,
    backend: backend ?? this.backend,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    buffered: buffered ?? this.buffered,
    playing: playing ?? this.playing,
    buffering: buffering ?? this.buffering,
    ready: ready ?? this.ready,
    completed: completed ?? this.completed,
    rate: rate ?? this.rate,
    error: error ?? this.error,
  );

  @override
  String toString() =>
      'PlaybackSnapshot(gen=$generation $backend pos=${position.inMilliseconds}ms '
      'dur=${duration.inMilliseconds}ms playing=$playing ready=$ready '
      'buffering=$buffering completed=$completed rate=$rate)';
}

/// A player implementation, not a feature framework.
///
/// Implementations own their decoder, their audio output and their listeners,
/// and publish [snapshots]. They never write controller state directly.
abstract class PlaybackBackend {
  PlaybackBackendKind get kind;

  /// Snapshot stream. Every event carries the generation the session assigned
  /// when it opened this backend.
  Stream<PlaybackSnapshot> get snapshots;

  /// Current snapshot, for code that needs a value instead of a stream.
  PlaybackSnapshot get snapshot;

  Future<void> open(PlaybackRequest request);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);
  Future<void> dispose();
}
