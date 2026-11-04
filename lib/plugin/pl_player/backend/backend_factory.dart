import 'package:PiliPlus/plugin/pl_player/backend/mpv_backend.dart';
import 'package:PiliPlus/plugin/pl_player/backend/native_backend.dart';
import 'package:PiliPlus/plugin/pl_player/backend/playback_backend.dart';
import 'package:PiliPlus/plugin/pl_player/utils/hdr_support.dart';
import 'package:media_kit/media_kit.dart';

/// Chooses the backend for one source.
///
/// A single decision point is the whole point: the quality ladder, the codec
/// and the platform capability are read once, and the winner is the only player
/// that is opened. The loser is not "paused" or "hidden" - it is never created.
class BackendFactory {
  const BackendFactory();

  /// Whether a rendition needs the native HDR path rather than mpv's 8-bit
  /// texture. Ten-bit is necessary but not sufficient for HDR; the capability
  /// gate lives in [HdrSupport].
  PlaybackBackendKind kindFor({
    required bool tenBitRendition,
    required bool isFileSource,
  }) {
    if (isFileSource) return PlaybackBackendKind.mpv;
    if (!tenBitRendition) return PlaybackBackendKind.mpv;
    if (!HdrSupport.nativeHdrPath) return PlaybackBackendKind.mpv;
    return PlaybackBackendKind.native;
  }

  MpvPlaybackBackend createMpv({
    required Player mediaPlayer,
    required int sourceGeneration,
    required Future<void> Function(PlaybackRequest) mediaOpener,
    Map<String, String>? mpvOptions,
  }) => MpvPlaybackBackend(
    mediaPlayer: mediaPlayer,
    sourceGeneration: sourceGeneration,
    mediaOpener: mediaOpener,
    mpvOptions: mpvOptions,
  );

  NativePlaybackBackend createNative({
    required String sessionId,
    required int generation,
  }) => NativePlaybackBackend(sessionId: sessionId, generation: generation);

  /// Mirrors [HdrSupport.nativeHdrPath] for tests that must not depend on the
  /// host platform they run on.
  bool get supportsNativeHdrPathForTest => HdrSupport.nativeHdrPath;
}
