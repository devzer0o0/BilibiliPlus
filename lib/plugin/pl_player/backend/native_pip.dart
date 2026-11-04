import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/backend/playback_route.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// Picture-in-Picture for the native AVPlayerLayer path.
///
/// The mpv path keeps its texture PiP (see IOSPipHelper). This one hands the
/// *existing* AVPlayerLayer to the system, so there is no second player, no
/// second audio output and no HDR round trip through an 8-bit texture.
///
/// State is explicit because "isAvailable" alone cannot tell a user why the
/// button did nothing: supported, possible, starting, active, stopping, failed.
enum NativePipState {
  unsupported,
  idle,
  starting,
  active,
  stopping,
  failed;

  bool get isBusy => this == starting || this == stopping;
  bool get isShowing => this == active;
}

@immutable
class NativePipStatus {
  const NativePipStatus({
    required this.state,
    this.sessionId,
    this.message,
  });

  final NativePipState state;

  /// The session this status belongs to. A status for a superseded session is
  /// ignored, so a late callbacks cannot re-open PiP for a source that is gone.
  final String? sessionId;
  final String? message;

  bool get isBusy => state.isBusy;
  bool get isShowing => state.isShowing;

  static const unsupported = NativePipStatus(
    state: NativePipState.unsupported,
  );

  @override
  String toString() =>
      'NativePipStatus(${state.name} session=${sessionId ?? '-'} '
      'msg=${message ?? '-'})';
}

/// Owns the PiP control channel and the state machine around it.
class NativePipCoordinator {
  NativePipCoordinator({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_controlChannel);

  static const _controlChannel = 'pilipilus/hdr_video/control';
  static const _eventChannel = 'pilipilus/hdr_video/events';

  /// Channel name, so tests can install a handler on the same one production
  /// uses instead of a copy of the string.
  static String get controlChannelForTest => _controlChannel;

  final MethodChannel _channel;
  StreamSubscription? _eventsSub;

  final _status = ValueNotifier<NativePipStatus>(NativePipStatus.unsupported);
  ValueListenable<NativePipStatus> get status => _status;

  String? _sessionId;

  /// Binds to a session and starts listening for PiP state.
  ///
  /// Called when the native backend opens; a new session replaces the old one
  /// so a status belonging to the previous source is dropped.
  Future<void> bind(String sessionId) async {
    _sessionId = sessionId;
    _eventsSub ??= const EventChannel(
      _eventChannel,
    ).receiveBroadcastStream().listen(_onEvent);
    _status.value = NativePipStatus(
      state: NativePipState.idle,
      sessionId: sessionId,
    );
  }

  /// Feeds one event through the same path the event channel uses.
  @visibleForTesting
  Future<void> debugHandleEvent(Object? raw) async => _onEvent(raw);

  void _onEvent(Object? raw) {
    if (raw is! Map || raw['event'] != 'pip') return;
    if (raw['sessionId'] != _sessionId) return;
    final state = switch (raw['state']) {
      'starting' => NativePipState.starting,
      'started' => NativePipState.active,
      'stopped' => NativePipState.idle,
      'failed' => NativePipState.failed,
      _ => null,
    };
    if (state == null) return;
    _status.value = NativePipStatus(
      state: state,
      sessionId: _sessionId,
      message: raw['message'] as String?,
    );
  }

  /// Starts PiP. Returns the status the UI should show.
  Future<NativePipStatus> start() async {
    final sessionId = _sessionId;
    if (sessionId == null) {
      return _fail('画中画不可用：没有活动播放会话');
    }
    if (_status.value.isShowing || _status.value.isBusy) {
      return _status.value;
    }
    _status.value = NativePipStatus(
      state: NativePipState.starting,
      sessionId: sessionId,
    );
    try {
      await _channel.invokeMethod<void>('pipStart', {'sessionId': sessionId});
      return _status.value;
    } catch (err) {
      return _fail('画中画启动失败：$err');
    }
  }

  Future<NativePipStatus> stop() async {
    final sessionId = _sessionId;
    if (sessionId == null) return _status.value;
    _status.value = NativePipStatus(
      state: NativePipState.stopping,
      sessionId: sessionId,
    );
    try {
      await _channel.invokeMethod<void>('pipStop', {'sessionId': sessionId});
      return _status.value;
    } catch (err) {
      return _fail('画中画退出失败：$err');
    }
  }

  /// Tells the native session that something outside it owns the intent.
  ///
  /// Used when PiP takes over or when an interruption pauses playback, so the
  /// stall recovery does not start playing again over a user's pause.
  Future<void> setInterrupted(bool interrupted) async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    try {
      await _channel.invokeMethod<void>('setInterrupted', {
        'sessionId': sessionId,
        'interrupted': interrupted,
      });
    } catch (_) {
      // Losing this hint must not break playback; the worst case is that the
      // stall recovery behaves like the previous version.
    }
  }

  NativePipStatus _fail(String message) {
    final status = NativePipStatus(
      state: NativePipState.failed,
      sessionId: _sessionId,
      message: message,
    );
    _status.value = status;
    return status;
  }

  Future<void> dispose() async {
    await _eventsSub?.cancel();
    _eventsSub = null;
    _sessionId = null;
    _status.value = NativePipStatus.unsupported;
    _status.dispose();
  }

  /// Whether the *active backend* can offer PiP.
  static bool supports(PlaybackRoute route) => route.isNative || route.isMpv;
}
