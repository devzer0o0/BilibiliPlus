import 'package:flutter/foundation.dart';

/// What remote playback the current media can actually support.
///
/// These are five different things and none of them substitutes for another:
///
///  * AirPlay video - the receiver pulls the media itself. The native path
///    serves an HLS presentation from a loopback bridge, which no receiver on
///    the network can reach, so this is not implemented and is refused.
///  * AirPlay audio - only the audio route changes; the picture stays local.
///  * System screen mirroring - the whole app is mirrored; nothing is handed
///    over, so it says nothing about the player.
///  * DLNA - a separate feature with its own transport.
///  * mpv's own texture path - never had external video either.
@immutable
class RemotePlaybackCapability {
  const RemotePlaybackCapability({
    required this.videoMirroring,
    required this.audioRouteOnly,
    this.reason,
  });

  /// Whether video could be sent to a remote receiver.
  final bool videoMirroring;

  /// Whether audio can be routed to AirPlay/Bluetooth while the picture stays.
  final bool audioRouteOnly;

  /// Why video is unavailable, for the UI to state rather than imply.
  final String? reason;

  /// The current media is served from a loopback bridge.
  static const loopback = RemotePlaybackCapability(
    videoMirroring: false,
    audioRouteOnly: true,
    reason: '当前媒体由本机桥接提供，接收端无法访问；AirPlay 仅支持音频输出',
  );

  /// A source with a receiver-reachable URL: not implemented in this build.
  static const remoteUnimplemented = RemotePlaybackCapability(
    videoMirroring: false,
    audioRouteOnly: true,
    reason: '远程视频播放尚未实现；音频输出路由可正常使用',
  );

  static RemotePlaybackCapability forSource({required bool loopback}) =>
      loopback ? RemotePlaybackCapability.loopback : remoteUnimplemented;
}
