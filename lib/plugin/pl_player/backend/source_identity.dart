import 'package:flutter/foundation.dart';

/// Who is playing what, and which switch it belongs to.
///
/// Four identities that used to be one integer:
///
///  * [sourceKey] - the media itself: content, quality, codec, audio track.
///    Re-opening the same rendition reuses it; it is what the platform view
///    keys its session on.
///  * [sessionId] - the running backend session. The native side stores one
///    session per key and replaces it on every open.
///  * [generation] - the media switch counter. Only a real source change
///    allocates one; rotation, full screen and control-bar toggles never do.
///  * [viewId] - the platform view. Owned by the widget layer, never by a
///    media switch.
///
/// The bug this fixes: the controller, `openNativeHdr` and
/// `PlaybackSession` each incremented their own counter, so the first native
/// open produced generation 2 at the top and generation 1 in the session. Every
/// event was then filtered as stale and the picture played with a frozen
/// progress bar.
@immutable
class MediaSourceIdentity {
  const MediaSourceIdentity({
    required this.sourceKey,
    required this.sessionId,
    required this.generation,
  });

  final String sourceKey;
  final String sessionId;
  final int generation;

  @override
  String toString() =>
      'MediaSourceIdentity($sourceKey session=$sessionId gen=$generation)';
}

/// The single place a media generation is allocated.
///
/// One allocator per player. [beginSourceChange] is called once, at the start
/// of a media switch transaction, and the number it returns is handed to the
/// session and the backend unchanged. Nothing downstream increments it.
class SourceGenerationAllocator {
  int _current = 0;

  int get current => _current;

  /// Starts a media switch and returns its generation.
  int beginSourceChange() => ++_current;

  /// True when [generation] is the newest one allocated.
  bool isCurrent(int generation) => generation == _current;

  /// Restores the counter after a state reset, so an old event cannot match a
  /// freshly reused value.
  void reset() => _current = 0;
}
