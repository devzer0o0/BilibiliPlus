/// Which backend owns playback right now, including the states between them.
///
/// A plain `videoPlayerController != null` check cannot express "mpv is being
/// created" or "the native session was disposed", so UI code that guarded on it
/// either ran commands against a half-built player or refused a command that
/// would have worked.
enum PlaybackRoute {
  /// No source has been requested yet.
  none,

  /// A source change is in flight; no backend is usable.
  preparing,

  /// media_kit's Player is the active backend.
  mpv,

  /// AVPlayerLayer is the active backend; mpv does not exist.
  native,

  /// The player was disposed. No command may be issued.
  disposed;

  bool get isMpv => this == PlaybackRoute.mpv;

  bool get isNative => this == PlaybackRoute.native;

  /// Whether any backend can accept a command.
  bool get canCommand => this == PlaybackRoute.mpv || this == PlaybackRoute.native;
}
