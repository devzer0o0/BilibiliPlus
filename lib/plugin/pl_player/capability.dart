import 'package:PiliPlus/plugin/pl_player/backend/playback_route.dart';
import 'package:flutter/foundation.dart';

/// What the active backend can do, right now.
///
/// Asking is cheaper than guessing: the UI used to force-unwrap
/// `videoPlayerController` and rely on it existing, which is exactly what does
/// not hold on the native HDR path and during a source change.
///
/// The route is part of the answer, not an afterthought: "no player yet" and
/// "the native player owns the picture" both mean "no mpv command", but only
/// the first is temporary.
@immutable
class PlaybackCapabilities {
  const PlaybackCapabilities({required this.isMpv, this.route = PlaybackRoute.none});

  /// True when media_kit's `Player` is the active backend.
  final bool isMpv;

  /// Where playback is, including `preparing` and `disposed`.
  final PlaybackRoute route;

  /// Super-resolution shaders, which are mpv's `glsl-shaders`.
  bool get shader => isMpv;
  bool get textureScreenshot => isMpv;
  bool get mixerVolume => isMpv;

  /// Switching the audio track inside one file is an mpv command; the native
  /// path would need a new HLS presentation.
  bool get audioTrackSwitch => isMpv;

  /// A frame can be grabbed from the running player.
  ///
  /// The native implementation is gated separately (see [nativeScreenshot]);
  /// claiming it here before it is verified would turn "screenshot failed" into
  /// "screenshot silently returned the wrong frame".
  bool get screenshot => isMpv;

  /// The native frame extractor, enabled once its verification passed.
  bool get nativeScreenshot => false;

  /// "Only play the audio" is a separate capability from choosing a track.
  bool get audioOnly => isMpv;

  /// PiP: mpv mirrors its texture; the native path needs its own controller.
  bool get pip => isMpv;

  bool get any => shader || screenshot || audioOnly;

  /// What to tell the user when they ask for [feature] on this backend.
  String unsupportedReason(String feature, PlaybackRoute? forRoute) {
    final route = forRoute ?? this.route;
    return switch (route) {
      PlaybackRoute.preparing => '$feature 正在准备播放，请稍候',
      PlaybackRoute.native => '$feature 暂不支持当前的原生播放路径',
      PlaybackRoute.disposed => '$feature 不可用：播放器已释放',
      PlaybackRoute.none => '$feature 不可用：尚未开始播放',
      PlaybackRoute.mpv => '$feature 不可用',
    };
  }
}
