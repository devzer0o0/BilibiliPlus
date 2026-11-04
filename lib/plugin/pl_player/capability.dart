import 'package:flutter/foundation.dart';

/// What the active backend can do.
///
/// Asking is cheaper than guessing: the UI used to force-unwrap
/// `videoPlayerController` and rely on it existing, which is exactly what does
/// not hold on the native HDR path.
@immutable
class PlaybackCapabilities {
  const PlaybackCapabilities({required this.isMpv});

  /// True when media_kit's `VideoController` is the active backend.
  final bool isMpv;

  /// Super-resolution shaders, which are mpv's `glsl-shaders`.
  bool get shader => isMpv;
  bool get textureScreenshot => isMpv;
  bool get mixerVolume => isMpv;

  /// Switching the audio track inside one file is an mpv command; the native
  /// path would need a new HLS presentation.
  bool get audioTrackSwitch => isMpv;

  bool get any => isMpv;
}
