import 'dart:async' show StreamSubscription, Timer;
import 'dart:convert' show ascii, utf8;
import 'dart:io' show Platform;
import 'dart:math' show max, min;
import 'dart:typed_data' show Uint8List;
import 'dart:ui' as ui;

import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/audio_normalization.dart';
import 'package:PiliPlus/models/common/super_resolution_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/user/danmaku_rule.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/models_new/video/video_shot/data.dart';
import 'package:PiliPlus/pages/danmaku/danmaku_model.dart';
import 'package:PiliPlus/pages/sponsor_block/block_mixin.dart';
import 'package:PiliPlus/plugin/pl_player/backend/native_frame_capture.dart';
import 'package:PiliPlus/plugin/pl_player/backend/native_pip.dart';
import 'package:PiliPlus/plugin/pl_player/backend/native_session_host.dart';
import 'package:PiliPlus/plugin/pl_player/backend/playback_route.dart';
import 'package:PiliPlus/plugin/pl_player/backend/source_identity.dart';
import 'package:PiliPlus/plugin/pl_player/capability.dart';
import 'package:PiliPlus/plugin/pl_player/backend/playback_backend.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/utils/hdr_support.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/double_tap_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/duration.dart';
import 'package:PiliPlus/plugin/pl_player/models/fullscreen_mode.dart';
import 'package:PiliPlus/plugin/pl_player/models/heart_beat_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/video_fit_type.dart';
import 'package:PiliPlus/plugin/pl_player/utils/danmaku_options.dart';
import 'package:PiliPlus/plugin/pl_player/utils/decoder_probe.dart';
import 'package:PiliPlus/plugin/pl_player/utils/diagnostics.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/asset_utils.dart';
import 'package:PiliPlus/utils/desktop/window_controller.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/extension/box_ext.dart';
import 'package:PiliPlus/utils/extension/native_geometry_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/ios/pip_helper.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:archive/archive.dart' show getCrc32;
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/foundation.dart'
    show ValueListenable, kDebugMode, visibleForTesting;
import 'package:flutter/services.dart'
    show DeviceOrientation, HapticFeedback, KeyDownEvent;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:native_device_orientation/native_device_orientation.dart';
import 'package:nativeapi/nativeapi.dart' as nativeapi show Size, Rectangle;
import 'package:path/path.dart' as path;
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

typedef PlayCallback = Future<void>? Function();
typedef PlayOwner = ({String tag, Type? type});

class PlPlayerController with BlockConfigMixin, AudioNormalizationMixin {
  Player? _videoPlayerController;
  VideoController? _videoController;

  static PlPlayerController? _instance;

  PlayerStatus playerStatus = .paused;

  final Rx<DataStatus> dataStatus = Rx(.none);

  Duration? seekToPos;
  bool hasToasted = false;
  final RxBool isSeeking = false.obs;

  final RxInt position = RxInt(0);
  final RxInt seekPosition = RxInt(0);
  int get progress =>
      isSeeking.value && hoverDx == null ? seekPosition.value : position.value;

  int get positionInMilliseconds => _snapshot.positionInMilliseconds;

  final RxInt buffered = RxInt(0);

  final RxInt duration = RxInt(0);

  int get durationInMilliseconds => _snapshot.durationInMilliseconds;

  void updateDuration(Duration value) {
    _snapshot = _snapshot.copyWith(duration: value);
    duration.value = value.inSeconds;
  }

  /// The single source of playback state for the UI.
  ///
  /// Both the mpv listener and the native event stream reduce into this, so
  /// `position`/`duration` (seconds) and `positionInMilliseconds`/
  /// `durationInMilliseconds` can never disagree - they are the same
  /// [PlaybackSnapshot].
  PlaybackSnapshot _snapshot = const PlaybackSnapshot();
  PlaybackSnapshot get snapshot => _snapshot;

  /// Which backend is publishing state right now.
  PlaybackBackendKind get activeBackend => _snapshot.backend;

  /// The only allocator of media generations in this player.
  ///
  /// A source change calls [SourceGenerationAllocator.beginSourceChange] once;
  /// the session, the backend and every event carry that number unchanged.
  final _generations = SourceGenerationAllocator();

  /// Events from a superseded source are dropped here, not in each listener.
  int get generation => _generations.current;

  /// Decoder counters from the running mpv, for measurement builds only.
  ///
  /// Returns an empty observation in a shipping build, where the probe is not
  /// compiled in. Callers must treat missing fields as unavailable, never 0.
  DecoderObservation sampleDecoder() {
    final player = _videoPlayerController;
    if (player == null || !Diagnostics.enabled) {
      return const DecoderObservation();
    }
    return DecoderProbe(player, enabled: true).sample();
  }

  /// Where playback currently is, including the states between backends.
  ///
  /// Derived rather than stored: it is a function of the backend that owns the
  /// snapshot and whether a source change is in flight.
  PlaybackRoute get route {
    if (_disposed) return PlaybackRoute.disposed;
    if (_routing == PlaybackRoute.disposed) return PlaybackRoute.disposed;
    if (_routing == PlaybackRoute.preparing) return PlaybackRoute.preparing;
    if (_nativeHost?.isOpen ?? false) return PlaybackRoute.native;
    if (_videoPlayerController != null) return PlaybackRoute.mpv;
    return _routing;
  }

  PlaybackRoute _routing = PlaybackRoute.none;
  /// True once [dispose] ran. Reads the route as `disposed` afterwards.
  bool get isDisposed => _disposed;

  bool _disposed = false;

  /// Whether this player page is in front of the user.
  ///
  /// Wake-lock and background policy are decided from this, not from mpv's own
  /// play/pause stream: the native backend has no such stream, and a stalled
  /// buffer is not the user putting the phone down.
  bool _isForeground = true;

  /// Wake-lock ownership, so mpv and native cannot disagree.
  bool _wakeLockHeld = false;

  /// Set when the app was paused because it went to the background, so only a
  /// pause this player caused is undone on return.
  bool _pausedForBackground = false;

  /// A toast must never be able to break a playback action.
  ///
  /// Every new capability refusal goes through here: the dialog host may not
  /// exist yet (headless tests, a route that is being torn down), and losing a
  /// message is recoverable while throwing out of a control handler is not.
  void _toast(String message) {
    try {
      SmartDialog.showToast(message);
    } catch (err) {
      if (kDebugMode) debugPrint('toast dropped: $message ($err)');
    }
  }

  /// Test seam: create a controller without touching platform plugins.
  ///
  /// The production constructor wires orientation and PiP listeners, which a
  /// widget/unit test has no business starting. Generation, routing, wake-lock
  /// and capability logic all live on the same object, so exercising them means
  /// constructing it the same way the app does.
  @visibleForTesting
  PlPlayerController.forTesting() {
    _instance = this;
  }

  /// Test seams for the generation/routing wiring.
  ///
  /// These call the same methods production does; none of them stamps a
  /// generation or replaces a policy with a test-only copy.
  @visibleForTesting
  int debugBeginSourceChange() => _generations.beginSourceChange();

  @visibleForTesting
  void debugSetRoute(PlaybackRoute route) => _routing = route;

  @visibleForTesting
  void debugOnNativeSnapshot(PlaybackSnapshot snapshot) =>
      _onNativeSnapshot(snapshot);

  @visibleForTesting
  PlaybackBackend Function(int generation, String sessionId)
  get debugNativeBackendFactory => (generation, sessionId) =>
      nativeBackendOverride!(generation, sessionId);

  @visibleForTesting
  void debugAdoptNativeHost(NativeSessionHost host) => _nativeHost = host;

  /// Applies one snapshot and fans it out to the UI and the business hooks.
  void applySnapshot(
    PlaybackSnapshot next, {
    String? debugLabel,
    bool notifyStatus = true,
  }) {
    if (next.generation != 0 && next.generation != generation) return;
    final previous = _snapshot;
    _snapshot = next;
    if (next.position.inSeconds != previous.position.inSeconds) {
      position.value = next.position.inSeconds;
    }
    if (next.duration.inSeconds != previous.duration.inSeconds) {
      duration.value = next.duration.inSeconds;
    }
    if (next.buffered.inSeconds != previous.buffered.inSeconds) {
      buffered.value = next.buffered.inSeconds;
    }
    if (next.buffering != previous.buffering) {
      isBuffering.value = next.buffering;
    }
    if ((next.playing || next.completed) != (previous.playing || previous.completed) &&
        notifyStatus) {
      playerStatus = next.completed
          ? .completed
          : (next.playing ? .playing : .paused);
      for (final listener in _statusListeners) {
        listener(playerStatus);
      }
    }
    _updatePlaybackState(debugLabel: debugLabel);
    _syncWakeLock();
  }

  int _playerCount = 0;

  late double lastPlaybackSpeed = 1.0;
  final RxDouble _playbackSpeed = Pref.playSpeedDefault.obs;
  late final RxDouble _longPressSpeed = Pref.longPressSpeedDefault.obs;

  final RxDouble volume = RxDouble(
    PlatformUtils.isDesktop ? Pref.desktopVolume : 1.0,
  );
  final setSystemBrightness = Pref.setSystemBrightness;

  final RxDouble brightness = (-1.0).obs;

  final RxBool showControls = false.obs;

  final RxBool showBrightnessStatus = false.obs;

  final RxBool longPressStatus = false.obs;

  final RxBool controlsLock = false.obs;

  final RxBool isFullScreen = false.obs;
  bool isLive = false;

  bool _isVertical = false;

  final Rx<VideoFitType> videoFit = Rx(.contain);

  late final RxBool continuePlayInBackground =
      Pref.continuePlayInBackground.obs;

  bool _autoPlay = false;

  // 记录历史记录
  int? _aid;
  String? _bvid;
  int? cid;
  int? _epid;
  int? _seasonId;
  int? _pgcType;
  VideoType _videoType = VideoType.ugc;
  int _heartDuration = 0;
  int? width;
  int? height;

  late final tryLook = !Accounts.get(AccountType.video).isLogin && Pref.p1080;

  late DataSource dataSource;

  Timer? _timer;
  StreamSubscription? _subForSeek;

  /// Legacy hook kept for callers that mirrored commands to the surface.
  ///
  /// The controller now owns the native session, so commands dispatch to it
  /// directly; the setter only records whether a surface is attached.
  void Function(String method, [Map? args])? get nativeControl => null;

  set nativeControl(void Function(String method, [Map? args])? value) {
    _nativeSurfaceAttached = value != null;
  }

  bool _nativeSurfaceAttached = false;

  /// True once the native platform view has been created and can render.
  bool get nativeSurfaceAttached => _nativeSurfaceAttached;

  /// The native HDR session, when AVPlayerLayer is the active backend.
  ///
  /// Ownership lives here rather than in the surface widget: a rebuild, a
  /// rotation or a full-screen toggle must not decide whether a business
  /// session exists.
  NativeSessionHost? _nativeHost;

  StreamSubscription<PlaybackSnapshot>? _nativeEvents;

  /// Test seam: the platform channels a native backend would use.
  @visibleForTesting
  PlaybackBackend Function(int generation, String sessionId)?
  nativeBackendOverride;

  /// Native PiP for the AVPlayerLayer path.
  ///
  /// Separate from IOSPipHelper, which mirrors the mpv texture: one of them is
  /// wrong for whichever backend is active, so they are chosen by route rather
  /// than both being offered.
  NativePipCoordinator? _nativePip;
  NativePipCoordinator get nativePip =>
      _nativePip ??= NativePipCoordinator();
  ValueListenable<NativePipStatus> get nativePipStatus =>
      nativePip.status;

  bool get _isNativeActive => route.isNative;

  bool get isNativeHdrActive => _isNativeActive;

  /// What the active backend can actually do.
  ///
  /// Callers use these instead of force-unwrapping `videoPlayerController`:
  /// an mpv-only feature on the native path is unavailable, and saying so is
  /// better than quietly doing nothing or crashing.
  PlaybackCapabilities get capabilities => PlaybackCapabilities(
    isMpv: route.isMpv && _videoPlayerController != null,
    route: route,
  );

  bool get supportsMpvCommands =>
      route.isMpv && _videoPlayerController != null;
  bool get supportsShader => capabilities.shader;
  bool get supportsTextureScreenshot => capabilities.textureScreenshot;
  bool get supportsMpvVolume => capabilities.mixerVolume;
  bool get supportsMpvAudioTrackSwitch => capabilities.audioTrackSwitch;
  bool get supportsNativeSurface => route.isNative;

  /// Opens the native session for [videoUrl].
  ///
  /// This does not wait for mpv: the native path used to require a completed
  /// mpv open before the surface was allowed to exist, which dead-locked the
  /// moment mpv was no longer created for HDR.
  Future<void> openNativeHdr({
    required PlaybackRequest request,
    required int generation,
  }) async {
    final host = _nativeHost ??= NativeSessionHost(
      onSnapshot: _onNativeSnapshot,
      backendFor: nativeBackendOverride == null
          ? null
          : (gen, sessionId) => nativeBackendOverride!(gen, sessionId),
    );
    _routing = PlaybackRoute.native;
    _nativeEvents?.cancel();
    _nativeEvents = null;
    await _nativePip?.bind(request.sourceKey);
    playerStatus = request.autoPlay ? PlayerStatus.playing : PlayerStatus.paused;
    await host.open(
      generation: generation,
      sessionId: request.sourceKey,
      request: request,
    );
  }

  /// The one place a native event becomes controller state.
  ///
  /// [NativeSessionHost] has already rejected anything whose generation is not
  /// the one this player opened, so nothing here re-stamps an old event.
  void _onNativeSnapshot(PlaybackSnapshot snapshot) {
    if (_disposed) return;
    applySnapshot(snapshot, notifyStatus: true);
    if (snapshot.position case final at when at > Duration.zero) {
      for (final listener in _positionListeners) {
        listener(at);
      }
    }
  }

  /// Stops the native session and returns ownership to mpv.
  Future<void> closeNativeHdr() async {
    // End PiP before the layer goes away: leaving it running means the system
    // holds a layer whose session is being disposed, which is how a black PiP
    // window with audio from nowhere appears.
    if (_nativePip?.status.value.isShowing ?? false) {
      await _nativePip?.stop();
    }
    await _nativeEvents?.cancel();
    _nativeEvents = null;
    final host = _nativeHost;
    _nativeHost = null;
    if (route == PlaybackRoute.native) _routing = PlaybackRoute.none;
    await host?.close();
  }

  Box setting = GStorage.setting;

  // final Durations durations;

  String get bvid => _bvid!;

  /// 视频播放速度
  double get playbackSpeed => _playbackSpeed.value;

  // 长按倍速
  double get longPressSpeed => _longPressSpeed.value;

  /// [videoPlayerController] instance of Player
  Player? get videoPlayerController => _videoPlayerController;

  /// [videoController] instance of Player
  VideoController? get videoController => _videoController;

  bool isMuted = false;

  /// 听视频 - play the audio track only.
  ///
  /// A capability-gated mode, not a flag the UI may flip: the header control
  /// used to set it and only then force-unwrap mpv to run a command on it.
  late final RxBool onlyPlayAudio = false.obs;

  /// Whether "listen to the video" is a *different* thing from choosing an
  /// audio track: a track switch keeps the picture.
  bool get audioOnlySupported => capabilities.audioOnly;

  /// Switches audio-only mode, or reports that it is unsupported.
  ///
  /// [onlyPlayAudio] changes only after the backend accepted the change, so a
  /// failure cannot leave the UI claiming a mode that is not running.
  Future<bool> setAudioOnly(bool enabled) async {
    if (onlyPlayAudio.value == enabled) return true;
    if (!capabilities.audioOnly) {
      _toast(capabilities.unsupportedReason('听视频', route));
      return false;
    }
    final player = _videoPlayerController;
    if (player == null) {
      _toast(capabilities.unsupportedReason('听视频', route));
      return false;
    }
    try {
      player.setProperty('file-local-options/vid', enabled ? 'auto' : 'no');
    } catch (err) {
      if (kDebugMode) debugPrint('setAudioOnly failed: $err');
      _toast('听视频切换失败');
      return false;
    }
    onlyPlayAudio.value = enabled;
    _syncWakeLock();
    _updatePlaybackState(debugLabel: 'onAudioOnlyChanged');
    return true;
  }

  /// 镜像
  late final RxBool flipX = false.obs;

  late final RxBool flipY = false.obs;

  final RxBool isBuffering = true.obs;

  /// 全屏方向
  // ignore: unnecessary_getters_setters
  bool get isVertical => _isVertical;

  set isVertical(bool value) {
    _isVertical = value;
  }

  /// 弹幕开关
  late final RxBool enableShowDanmaku = Pref.enableShowDanmaku.obs;
  late final RxBool enableShowLiveDanmaku = Pref.enableShowLiveDanmaku.obs;
  RxBool get enableShowDanmakuAdaptive =>
      isLive ? enableShowLiveDanmaku : enableShowDanmaku;

  late final bool autoPiP = Pref.autoPiP;
  bool get isPipMode =>
      (Platform.isAndroid && AndroidHelper.isPipMode) ||
      (PlatformUtils.isDesktop && isDesktopPip);
  late bool isDesktopPip = false;
  late nativeapi.Rectangle _lastWindowBounds;
  static nativeapi.Rectangle? _lastPipBounds;

  nativeapi.Rectangle _adjustPipBounds(
    nativeapi.Rectangle lastRect,
    nativeapi.Size size,
    double aspectRatio,
  ) {
    final lastSize = lastRect.size;
    final lastOrientation = lastSize.orientation;
    final orientation = size.orientation;

    if (lastOrientation != orientation) {
      final double width, height;
      switch (orientation) {
        case .portrait:
          if (lastSize.width > size.height) {
            height = min(lastSize.width, _lastWindowBounds.size.height);
            width = height * aspectRatio;
          } else {
            height = size.height;
            width = size.width;
          }
        case .landscape:
          if (lastSize.height > size.width) {
            width = lastSize.height;
            height = width / aspectRatio;
          } else {
            height = size.height;
            width = size.width;
          }
      }

      return _lastPipBounds = nativeapi.Rectangle(
        x: lastRect.x,
        y: lastRect.y,
        width: width,
        height: height,
      );
    }
    return _lastPipBounds = nativeapi.Rectangle(
      x: lastRect.x,
      y: lastRect.y,
      width: lastSize.width,
      height: lastSize.width / aspectRatio,
    );
  }

  bool updatePipBounds(Window window) {
    if (isDesktopPip) {
      _lastPipBounds = window.bounds;
      return true;
    }
    return false;
  }

  late final showWindowTitleBar = Pref.showWindowTitleBar;
  late final RxBool isAlwaysOnTop = false.obs;
  void setAlwaysOnTop(bool value, {Window? window}) {
    window ??= WindowController.instance.window;
    if (window == null) return;

    isAlwaysOnTop.value = value;
    window.isAlwaysOnTop = value;
  }

  void exitDesktopPip() {
    final window = WindowController.instance.window;
    if (window == null) return;

    isDesktopPip = false;
    if (showWindowTitleBar) window.titleBarStyle = .normal;
    window
      ..minimumSize = DeviceUtils.desktopMinSize
      ..bounds = _lastWindowBounds
      ..aspectRatio = 0;
    setAlwaysOnTop(false, window: window);
  }

  void enterDesktopPip() {
    final window = WindowController.instance.window;
    if (window == null) return;

    if (isFullScreen.value) return;

    isDesktopPip = true;

    _lastWindowBounds = window.bounds;

    if (showWindowTitleBar) window.titleBarStyle = .hidden;

    const shortSide = 280.0;
    const minShortSide = 160.0;
    final nativeapi.Size size;
    final nativeapi.Size minimumSize;
    final state = videoPlayerController?.state;
    int width = state?.width ?? 0;
    int height = state?.height ?? 0;
    if (width == 0) width = this.width ?? 16;
    if (height == 0) height = this.height ?? 9;
    final aspectRatio = width / height;
    if (height > width) {
      size = nativeapi.Size(width: shortSide, height: shortSide / aspectRatio);
      minimumSize = nativeapi.Size(
        width: minShortSide,
        height: minShortSide / aspectRatio,
      );
    } else {
      size = nativeapi.Size(width: shortSide * aspectRatio, height: shortSide);
      minimumSize = nativeapi.Size(
        width: minShortSide * aspectRatio,
        height: minShortSide,
      );
    }

    window.minimumSize = minimumSize;
    setAlwaysOnTop(true, window: window);
    if (_lastPipBounds != null) {
      window.bounds = _adjustPipBounds(_lastPipBounds!, size, aspectRatio);
    } else {
      window.contentSize = size;
    }
    window.aspectRatio = aspectRatio;
  }

  void toggleDesktopPip() {
    if (isDesktopPip) {
      exitDesktopPip();
    } else {
      enterDesktopPip();
    }
  }

  late bool _isAutoEnterPip = false;
  bool get isAutoEnterPip => _isAutoEnterPip;

  static bool get _isCurrVideoPage {
    final routing = Get.routing;
    if (routing.route is! GetPageRoute) {
      return false;
    }
    return _isVideoPage(routing.current);
  }

  static bool _isVideoPage(String routeName) {
    return routeName == '/videoV' || routeName == '/liveRoom';
  }

  /// Enters PiP on whichever backend is active.
  ///
  /// The two paths are genuinely different: mpv hands over its texture, the
  /// native path hands over the AVPlayerLayer. Choosing by route is what stops
  /// a texture id from being requested for a player that has none.
  Future<void> enterPip({bool autoEnter = false}) async {
    if (route.isNative) {
      final status = await nativePip.start();
      if (status.state == NativePipState.failed) {
        _toast(status.message ?? '画中画启动失败');
      }
      return;
    }
    final player = videoPlayerController;
    if (player != null) {
      final state = player.state;
      if (Platform.isIOS) {
        if (videoController?.id.value case final textureId?) {
          IOSPipHelper.enter(
            textureId,
            width: state.width == 0 ? width : state.width,
            height: state.height == 0 ? height : state.height,
            autoEnter: autoEnter,
            state: _iosPipState(),
          );
        }
        return;
      }
      PageUtils.enterPip(
        autoEnter: autoEnter,
        width: state.width == 0 ? width : state.width,
        height: state.height == 0 ? height : state.height,
        isLive: isLive,
        isPlaying: playerStatus.isPlaying,
      );
      return;
    }
    _toast(capabilities.unsupportedReason('画中画', route));
  }

  /// Enters PiP automatically on the native path when the app is backgrounded.
  ///
  /// Called from the lifecycle handler instead of mpv's playing stream, which
  /// never fires for AVPlayerLayer.
  Future<void> _maybeAutoEnterPipOnBackground() async {
    if (!_isAutoEnterPip || !_isCurrVideoPage || !_snapshot.playing) return;
    await enterPip(autoEnter: true);
  }

  void _disableAutoEnterPip() {
    if (_isAutoEnterPip) {
      if (Platform.isIOS) {
        IOSPipHelper.disableAutoEnter();
      } else {
        PiliAndroidHelper.disableAutoEnterPip();
      }
    }
  }

  Map<String, Object> _iosPipState() {
    return {
      'isPlaying': playerStatus.isPlaying,
      'isBuffering': isBuffering.value,
      'isLive': isLive,
      'position': _snapshot.positionInMilliseconds,
      'duration': _snapshot.durationInMilliseconds,
      'speed': _snapshot.rate,
    };
  }

  /// iOS PiP still mirrors the mpv texture, so it is only offered when mpv is
  /// the active backend; the native HDR surface has no texture id to hand over.
  void _updateIOSPip([Duration? position]) {
    if (Platform.isIOS &&
        IOSPipHelper.needsUpdate &&
        _snapshot.backend == PlaybackBackendKind.mpv &&
        _videoPlayerController != null) {
      IOSPipHelper.update(_iosPipState());
    }
  }

  // 弹幕相关配置
  late final enableTapDm = PlatformUtils.isMobile && Pref.enableTapDm;
  late RuleFilter filters = Pref.danmakuFilterRule;
  // 关联弹幕控制器
  DanmakuController<DanmakuExtra>? danmakuController;
  bool showDanmaku = true;
  Set<int> dmState = <int>{};
  late final mergeDanmaku = Pref.mergeDanmaku;
  late final String midHash = getCrc32(
    ascii.encode(Accounts.main.mid.toString()),
    0,
  ).toRadixString(16);
  late final RxDouble danmakuOpacity = Pref.danmakuOpacity.obs;

  late List<double> speedList = Pref.speedList;
  late bool enableAutoLongPressSpeed = Pref.enableAutoLongPressSpeed;
  late final showControlDuration = Pref.enableLongShowControl
      ? const Duration(seconds: 30)
      : const Duration(seconds: 3);
  // 字幕
  late double subtitleFontScale = Pref.subtitleFontScale;
  late double subtitleFontScaleFS = Pref.subtitleFontScaleFS;
  late int subtitlePaddingH = Pref.subtitlePaddingH;
  int? tmpSubtitlePaddingB;
  late int subtitlePaddingB = Pref.subtitlePaddingB;
  late double subtitleBgOpacity = Pref.subtitleBgOpacity;
  final bool showVipDanmaku = Pref.showVipDanmaku; // loop unswitching
  late double subtitleStrokeWidth = Pref.subtitleStrokeWidth;
  late int subtitleFontWeight = Pref.subtitleFontWeight;

  // settings
  late final showFSActionItem = Pref.showFSActionItem;
  late final enableShrinkVideoSize = Pref.enableShrinkVideoSize;
  late final darkVideoPage = Pref.darkVideoPage;
  late final enableSlideVolumeBrightness = Pref.enableSlideVolumeBrightness;
  late final enableSlideFS = Pref.enableSlideFS;
  late final enableScrollVolume = Pref.enableScrollVolume;
  late final enableDragSubtitle = Pref.enableDragSubtitle;
  late final fastForBackwardInSeconds = Pref.fastForBackwardDuration;
  late final fastForBackwardDuration = Duration(
    seconds: fastForBackwardInSeconds,
  );

  late final horizontalSeasonPanel = Pref.horizontalSeasonPanel;
  late final preInitPlayer = Pref.preInitPlayer;
  late final showRelatedVideo = Pref.showRelatedVideo;
  late final showVideoReply = Pref.showVideoReply;
  late final showBangumiReply = Pref.showBangumiReply;
  late final reverseFromFirst = Pref.reverseFromFirst;
  late final horizontalPreview = Pref.horizontalPreview;
  late final showDmChart = Pref.showDmChart;
  late final showViewPoints = Pref.showViewPoints;
  late final showFsScreenshotBtn = Pref.showFsScreenshotBtn;
  late final showFsLockBtn = Pref.showFsLockBtn;
  late final keyboardControl = Pref.keyboardControl;
  late final uiScale = Pref.uiScale;

  late final bool autoEnterFullScreen = Pref.autoEnterFullScreen;
  late final bool autoExitFullscreen = Pref.autoExitFullscreen;
  late final bool autoPlayEnable = Pref.autoPlayEnable;
  late final bool enableVerticalExpand = Pref.enableVerticalExpand;
  late final bool pipNoDanmaku = Pref.pipNoDanmaku;

  late final bool tempPlayerConf = Pref.tempPlayerConf;

  late int? cacheVideoQa = PlatformUtils.isMobile || Platform.isLinux
      ? null
      : Pref.defaultVideoQa;
  late int cacheAudioQa = Pref.defaultAudioQa;
  bool enableHeart = true;
  late final String? hwdec = Pref.enableHA ? Pref.hardwareDecoding : null;

  late final progressType = Pref.btmProgressBehavior;
  late final enableQuickDouble = Pref.enableQuickDouble;
  late final fullScreenGestureReverse = Pref.fullScreenGestureReverse;

  late final isRelative = Pref.useRelativeSlide;
  late final offset = isRelative
      ? Pref.sliderDuration / 100
      : Pref.sliderDuration * 1000;

  num get sliderScale => isRelative ? durationInMilliseconds * offset : offset;

  // 播放顺序相关
  late PlayRepeat playRepeat = Pref.playRepeat;

  TextStyle get subTitleStyle => TextStyle(
    height: 1.5,
    fontSize:
        16 * (isFullScreen.value ? subtitleFontScaleFS : subtitleFontScale),
    letterSpacing: 0.1,
    wordSpacing: 0.1,
    color: Colors.white,
    fontWeight: FontWeight.values[subtitleFontWeight],
    backgroundColor: subtitleBgOpacity == 0
        ? null
        : Colors.black.withValues(alpha: subtitleBgOpacity),
  );

  late final Rx<SubtitleViewConfiguration> subtitleConfig = getSubConfig.obs;

  SubtitleViewConfiguration get getSubConfig {
    final subTitleStyle = this.subTitleStyle;
    return SubtitleViewConfiguration(
      style: subTitleStyle,
      strokeStyle: subtitleBgOpacity == 0
          ? subTitleStyle.copyWith(
              color: null,
              background: null,
              backgroundColor: null,
              foreground: Paint()
                ..color = Colors.black
                ..style = PaintingStyle.stroke
                ..strokeWidth = subtitleStrokeWidth,
            )
          : null,
      padding: EdgeInsets.only(
        left: subtitlePaddingH.toDouble(),
        right: subtitlePaddingH.toDouble(),
        bottom: subtitlePaddingB.toDouble(),
      ),
      textScaleFactor: 1,
    );
  }

  void updateSubtitleStyle() {
    subtitleConfig.value = getSubConfig;
  }

  void onUpdatePadding(EdgeInsets padding) {
    tmpSubtitlePaddingB = null;
    subtitlePaddingB = padding.bottom.round().clamp(0, 200);
    updateSubtitleStyle();
    putSubtitleSettings();
  }

  static PlPlayerController? get instance => _instance;

  static bool instanceExists() {
    return _instance != null;
  }

  static void setPlayCallBack(
    PlayCallback? playCallBack, {
    PlayOwner? playOwner,
  }) {
    _playCallBack = playCallBack;
    _playOwner = playOwner;
  }

  static PlayOwner? _playOwner;
  static PlayOwner? get playOwner => _playOwner;
  static PlayCallback? _playCallBack;

  static Future<void>? playIfExists() {
    return _playCallBack?.call();
  }

  // try to get PlayerStatus
  static PlayerStatus? getPlayerStatusIfExists() {
    return _instance?.playerStatus;
  }

  static Future<void>? pauseIfExists({
    bool notify = true,
    bool isInterrupt = false,
  }) {
    if (_instance?.playerStatus.isPlaying ?? false) {
      return _instance?.pause(notify: notify, isInterrupt: isInterrupt);
    }
    return null;
  }

  static Future<void>? seekToIfExists(
    Duration position, {
    bool isSeek = true,
  }) {
    return _instance?.seekTo(position, isSeek: isSeek);
  }

  static double? getVolumeIfExists() {
    return _instance?.volume.value;
  }

  static Future<void>? setVolumeIfExists(
    double volumeNew, {
    bool showIndicator = true,
  }) {
    return _instance?.setVolume(volumeNew, showIndicator: showIndicator);
  }

  Box video = GStorage.video;

  bool visible = true;

  DeviceOrientation? _orientation;
  late final checkIsAutoRotate = Platform.isAndroid && mode != .gravity;
  StreamSubscription<OrientationParams>? _orientationListener;

  void _stopOrientationListener() {
    _orientationListener?.cancel();
    _orientationListener = null;
  }

  void _onOrientationChanged(OrientationParams param) {
    _orientation = param.orientation;
    if (Platform.isIOS && !visible) return;
    if (controlsLock.value) return;
    final orientation = param.orientation;
    final isFullScreen = this.isFullScreen.value;
    if (checkIsAutoRotate &&
        param.isAutoRotate != true &&
        (!isFullScreen ||
            _isVertical ||
            orientation == .portraitUp ||
            orientation == .portraitDown)) {
      return;
    }
    switch (orientation) {
      case .portraitUp:
        if (!horizontalScreen && !_isVertical && isFullScreen) {
          if (!isManualFS) {
            triggerFullScreen(status: false, orientation: orientation);
          }
        } else {
          portraitUpMode();
        }
      case .portraitDown:
        if (!horizontalScreen) return;
        portraitDownMode();
      case .landscapeLeft:
        if (!horizontalScreen && !isFullScreen) {
          triggerFullScreen(orientation: orientation, isManualFS: false);
        } else {
          landscapeLeftMode();
        }
      case .landscapeRight:
        if (!horizontalScreen && !isFullScreen) {
          triggerFullScreen(orientation: orientation, isManualFS: false);
        } else {
          landscapeRightMode();
        }
    }
  }

  // 添加一个私有构造函数
  PlPlayerController._() {
    if (PlatformUtils.isMobile) {
      _orientationListener = NativeDeviceOrientationPlatform.instance
          .onOrientationChanged(
            checkIsAutoRotate: checkIsAutoRotate,
            angleDegrees: Platform.isAndroid ? Pref.angleDegrees : null,
          )
          .listen(_onOrientationChanged);
    }

    if (!Accounts.heartbeat.isLogin || Pref.historyPause) {
      enableHeart = false;
    }

    if (Platform.isAndroid && autoPiP) {
      if (DeviceUtils.sdkInt < 31) {
        final func = Runnable.implement($Runnable(run: _onUserLeaveHint));
        AndroidHelper$ToDart.onUserLeaveHint = func;
        func.release();
      } else {
        _isAutoEnterPip = true;
      }
    } else if (Platform.isIOS && autoPiP && IOSPipHelper.isAvailable) {
      _isAutoEnterPip = true;
    }
  }

  void _onUserLeaveHint() {
    if (playerStatus.isPlaying && _isCurrVideoPage) {
      enterPip(autoEnter: true);
    }
  }

  // 获取实例 传参
  static PlPlayerController getInstance({bool isLive = false}) {
    // 如果实例尚未创建，则创建一个新实例
    return (_instance ??= PlPlayerController._())
      ..isLive = isLive
      .._playerCount += 1;
  }

  bool _processing = false;
  bool get processing => _processing;

  // offline
  bool get isFileSource => dataSource is FileSource;

  // 初始化资源
  Future<void> setDataSource(
    DataSource dataSource, {
    bool isLive = false,
    bool autoplay = true,
    // 初始化播放位置
    Duration? seekTo,
    // 初始化播放速度
    double speed = 1.0,
    int? width,
    int? height,
    Duration? duration,
    // 方向
    bool? isVertical,
    // 记录历史记录
    int? aid,
    String? bvid,
    int? cid,
    int? epid,
    int? seasonId,
    int? pgcType,
    VideoType? videoType,
    VoidCallback? onInit,
    Volume? volume,
    bool autoFullScreenFlag = false,
    int? rotate,
    // Native HDR routing: when set, AVPlayerLayer is the only backend and mpv
    // is never opened. The decision is made by the caller because only it
    // knows the rendition, the codec and the platform capability.
    String? nativeHdrUrl,
    String? nativeHdrAudioUrl,
    SegmentBaseRange? nativeVideoRange,
    SegmentBaseRange? nativeAudioRange,
    String? nativeVideoCodecs,
    String? nativeAudioCodecs,
    int? nativeWidth,
    int? nativeHeight,
    String? nativeFrameRate,
    String? sourceKey,
  }) async {
    try {
      _processing = true;
      this.isLive = isLive;
      _videoType = videoType ?? VideoType.ugc;
      this.width = width;
      this.height = height;
      this.dataSource = dataSource;
      _autoPlay = autoplay;
      // 初始化数据加载状态
      dataStatus.value = DataStatus.loading;
      // 初始化全屏方向
      _isVertical = isVertical ?? false;
      _aid = aid;
      _bvid = bvid;
      this.cid = cid;
      _epid = epid;
      _seasonId = seasonId;
      _pgcType = pgcType;

      if (showSeekPreview) {
        _clearPreview();
      }
      cancelLongPressTimer();
      if (_videoPlayerController != null &&
          _videoPlayerController!.state.playing) {
        await pause(notify: false);
      }

      if (_playerCount == 0) {
        return;
      }

      final useNative = nativeHdrUrl != null && nativeHdrUrl.isNotEmpty;

      // One media switch, one generation, allocated here and nowhere else.
      // The session and the backend receive this number unchanged; the surface
      // key stays [sourceKey] so a live-retry of the same rendition re-uses the
      // platform view instead of rebuilding it.
      final generation = _generations.beginSourceChange();
      final key =
          sourceKey ??
          'native:${_bvid ?? ''}:${this.cid ?? 0}:$generation';

      if (!useNative) {
        // Leaving the native path has to tear it down before mpv opens, or the
        // old AVPlayer keeps decoding underneath the new picture.
        if (_nativeHost != null || _snapshot.backend == PlaybackBackendKind.native) {
          await closeNativeHdr();
          _snapshot = const PlaybackSnapshot();
        }
        _routing = PlaybackRoute.preparing;
        // 配置Player 音轨、字幕等等
        await _createVideoController(dataSource, seekTo, volume, rotate);

        if (_playerCount == 0) {
          _removeListeners();
          _videoPlayerController?.dispose();
          _videoPlayerController = null;
          _videoController = null;
          return;
        }

        updateDuration(duration ?? _videoPlayerController!.state.duration);
        position.value = buffered.value = seekTo?.inSeconds ?? 0;

        dataStatus.value = .loaded;

        if (autoFullScreenFlag && autoEnterFullScreen) {
          triggerFullScreen(status: true);
        }

        await _initializePlayer();
        if (!_disposed && _videoPlayerController != null) {
          _routing = PlaybackRoute.mpv;
        }
      } else {
        // Native path: no mpv is created, so nothing has to be waited for and
        // nothing can play underneath. Duration comes from the session.
        _snapshot = PlaybackSnapshot(
          generation: generation,
          backend: PlaybackBackendKind.native,
          position: seekTo ?? Duration.zero,
          duration: duration ?? Duration.zero,
          rate: isLive ? 1.0 : playbackSpeed,
        );
        position.value = seekTo?.inSeconds ?? 0;
        buffered.value = 0;
        isBuffering.value = true;
        dataStatus.value = DataStatus.loaded;
        if (autoFullScreenFlag && autoEnterFullScreen) {
          triggerFullScreen(status: true);
        }
        await openNativeHdr(
          generation: generation,
          request: PlaybackRequest(
            sourceKey: key,
            videoUrl: nativeHdrUrl,
            audioUrl: nativeHdrAudioUrl,
            videoSegmentBase: nativeVideoRange,
            audioSegmentBase: nativeAudioRange,
            videoCodecs: nativeVideoCodecs,
            audioCodecs: nativeAudioCodecs,
            width: nativeWidth,
            height: nativeHeight,
            frameRate: nativeFrameRate,
            startPosition: seekTo,
            autoPlay: _autoPlay,
            rate: isLive ? 1.0 : playbackSpeed,
            isLive: isLive,
          ),
        );
        _initVideoFit();
      }
      onInit?.call();
    } catch (err, stackTrace) {
      dataStatus.value = DataStatus.error;
      if (kDebugMode) {
        debugPrint(stackTrace.toString());
        debugPrint('plPlayer err:  $err');
      }
    } finally {
      _processing = false;
    }
  }

  String? shadersDirPath;
  Future<String> get copyShadersToExternalDirectory async {
    if (shadersDirPath != null) {
      return shadersDirPath!;
    }

    return shadersDirPath = await AssetUtils.getOrCopy(
      'assets/shaders',
      Assets.mpvAnime4KShaders.followedBy(Assets.mpvAnime4KShadersLite),
      path.join(appSupportDirPath, 'anime_shaders'),
    );
  }

  late final isAnim = _pgcType == 1 || _pgcType == 4;
  late final Rx<SuperResolutionType> superResolutionType =
      (isAnim ? Pref.superResolutionType : SuperResolutionType.disable).obs;
  /// Applies a super-resolution preset, or explains why it cannot be applied.
  ///
  /// The order matters and used to be wrong: the preference was written first,
  /// then the command was sent to a player that may not exist, so the UI showed
  /// "enabled" for a shader nothing had loaded. Now the capability is checked
  /// first, the command has to succeed, and only then does the selection and
  /// the stored preference change. Leaving the native path does not erase the
  /// user's mpv preference either - it is simply not active there.
  Future<bool> setShader([SuperResolutionType? type, NativePlayer? pp]) async {
    final requested = type ?? superResolutionType.value;
    final target = pp ?? _videoPlayerController;
    if (!capabilities.shader || target == null) {
      if (type != null) {
        _toast('超分辨率仅在 mpv 播放路径可用');
      }
      return false;
    }
    // The command is built before anything is mutated, because resolving the
    // shader path is asynchronous and may fail.
    final List<String>? command = switch (requested) {
      SuperResolutionType.disable => const [
        'change-list',
        'glsl-shaders',
        'clr',
        '',
      ],
      SuperResolutionType.efficiency => [
        'change-list',
        'glsl-shaders',
        'set',
        PathUtils.buildShadersAbsolutePath(
          await copyShadersToExternalDirectory,
          Assets.mpvAnime4KShadersLite,
        ),
      ],
      SuperResolutionType.quality => [
        'change-list',
        'glsl-shaders',
        'set',
        PathUtils.buildShadersAbsolutePath(
          await copyShadersToExternalDirectory,
          Assets.mpvAnime4KShaders,
        ),
      ],
    };
    if (command == null) return false;
    // Copying the shader assets yields to the event loop; the player may have
    // been swapped for the native path while that happened.
    if (!capabilities.shader || !identical(target, _videoPlayerController)) {
      return false;
    }
    try {
      await target.command(command);
    } catch (err) {
      if (kDebugMode) debugPrint('setShader failed: $err');
      _toast('超分辨率设置失败');
      return false;
    }
    // Applied: only now is the selection worth showing.
    superResolutionType.value = requested;
    if (isAnim && !tempPlayerConf) {
      setting.put(SettingBoxKey.superResolutionType, requested.index);
    }
    return true;
  }

  Future<Player> _initPlayer() async {
    assert(_videoPlayerController == null);
    final opt = {
      'video-sync': Pref.videoSync,
      if (Platform.isAndroid) 'ao': Pref.audioOutput,
      // iOS：显式让 mpv 对所有支持的编码尝试硬解。iPhone Air 的
      // VideoToolbox 支持 H.264/HEVC/VP9/AV1，缺少这一项时 AV1 可能
      // 仍走 libdav1d 软解。
      'hwdec-codecs': 'all',
      'volume':
          (PlatformUtils.isMobile ? Pref.playerVolume : volume.value * 100)
              .toString(),
      // HDR streams (HDR10/HLG, Dolby Vision) decode to 10-bit. The Darwin
      // VideoToolbox path hands frames to media_kit as p010, but the Flutter
      // texture is 8-bit BGRA, so without tone mapping the picture renders
      // with swapped chroma (green). Pay for the conversion only when the
      // texture is actually going to draw the frames - on iOS the HDR ladder is
      // handed to AVPlayerLayer instead, so mpv never sees them and the
      // conversion would be wasted work.
      if (HdrSupport.allowsHdrQuality && !HdrSupport.nativeHdrPath)
        ...HdrSupport.toneMappedPlayerOptions,
    };
    final autosync = Pref.autosync;
    if (autosync != '0') {
      opt['autosync'] = autosync;
    }

    final player = await Player.create(
      configuration: PlayerConfiguration(
        logLevel: kDebugMode ? .warn : .error,
        options: opt,
      ),
    );

    assert(_videoController == null);

    _videoController = await VideoController.create(
      player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: hwdec != null,
        androidAttachSurfaceAfterVideoParameters: false,
        hwdec: hwdec,
      ),
    );

    if (Platform.isAndroid) {
      // Avoid sizing the surface using mpv's idle window between media loads.
      player.setProperty('force-window', 'no');
    }

    player.setMediaHeader(userAgent: BrowserUa.pc, referer: HttpString.baseUrl);

    _startListeners(player);

    return player;
  }

  late final buffer = Pref.initBuffer(_playbackSpeed.value);
  late final liveBuffer = Pref.initLiveBuffer();

  // 配置播放器
  Future<void> _createVideoController(
    DataSource dataSource,
    Duration? seekTo,
    Volume? volume,
    int? rotate,
  ) async {
    isBuffering.value = false;
    _heartDuration = 0;
    danmakuController?.clear();

    var player = _videoPlayerController;

    if (player == null) {
      player = await _initPlayer();
      if (_playerCount == 0) {
        _removeListeners();
        player.dispose();
        player = null;
        _videoController = null;
        return;
      }
      _videoPlayerController = player;
      if (isAnim && superResolutionType.value != .disable) {
        await setShader();
      }
    }

    final Map<String, String> extras = {
      if (dataSource is FileSource)
        'cache': 'no'
      else if (isLive)
        ...liveBuffer
      else
        ...buffer,
      'video-rotate': ?rotate?.toString(),
    };

    String video = dataSource.videoSource;
    if (dataSource.audioSource case final audio? when (audio.isNotEmpty)) {
      if (onlyPlayAudio.value) {
        video = audio;
      } else {
        // dely_open need provide length
        video =
            ('edl://'
            '!no_chapters;'
            // '!delay_open,media_type=video;'
            '%${isFileSource ? utf8.encode(video).length : video.length}%$video;'
            '!new_stream;!no_chapters;'
            // '!delay_open,media_type=audio;'
            '%${isFileSource ? utf8.encode(audio).length : audio.length}%$audio');
      }
      audioFilterExtras(volume, map: extras);
    }

    assert(!isLive || seekTo == null);
    await player.open(
      Media(
        video,
        start: seekTo,
        extras: extras.isEmpty ? null : extras,
      ),
      play: false,
    );
  }

  Future<void>? refreshPlayer() {
    if (dataSource is FileSource) {
      return null;
    }
    if (_videoPlayerController case final ctr? when (ctr.current.isNotEmpty)) {
      var media = ctr.current.last;
      if (!isLive) media = media.copyWith(start: ctr.state.position);
      return ctr.open(media, play: true);
    }
    return null;
  }

  // 开始播放
  Future<void> _initializePlayer() async {
    if (_instance == null) return;
    // 设置倍速
    if (_videoPlayerController != null) {
      final speed = isLive ? 1.0 : playbackSpeed;
      if (_videoPlayerController!.state.rate != speed) {
        await setPlaybackSpeed(speed);
      }
    }
    _initVideoFit();

    // 自动播放
    if (_autoPlay) {
      playIfExists();
    }
  }

  List<StreamSubscription>? _subscriptions;
  final Set<ValueChanged<Duration>> _positionListeners = {};
  final Set<ValueChanged<PlayerStatus>> _statusListeners = {};

  Timer? _wakeLockTimer;

  void _startWakeLockTimer() {
    _wakeLockTimer?.cancel();
    _wakeLockTimer = Timer(
      const Duration(milliseconds: 500),
      _stopWakeLock,
    );
  }

  void _stopWakeLockTimer() {
    _wakeLockTimer?.cancel();
    _wakeLockTimer = null;
  }

  void _stopWakeLock() {
    _disableWakeLock();
    _updatePlaybackState(debugLabel: 'onVideoPaused');
  }

  void _enableWakeLock() {
    if (_wakeLockHeld) return;
    _wakeLockHeld = true;
    WakelockPlus.enable();
  }

  void _disableWakeLock() {
    if (!_wakeLockHeld) return;
    _wakeLockHeld = false;
    WakelockPlus.disable();
  }

  /// The single screen-wake policy for both backends.
  ///
  /// A video that is on screen and playing keeps the display on. Everything
  /// else releases it: paused, buffering, backgrounded, audio-only (there is no
  /// picture to protect) or disposed. Driving this from the shared snapshot is
  /// what makes the native path behave like the mpv one - it has no
  /// `stream.playing` listener to hang the old code off.
  void _syncWakeLock() {
    if (_disposed) {
      _disableWakeLock();
      return;
    }
    final wantsWakeLock =
        _isForeground && isPlayerPageForeground && !onlyPlayAudio.value &&
        _snapshot.backend != PlaybackBackendKind.none &&
        _snapshot.playing && !_snapshot.buffering && !_snapshot.completed;
    if (wantsWakeLock) {
      _enableWakeLock();
    } else {
      _disableWakeLock();
    }
  }

  /// Whether the player is the page the user is looking at.
  ///
  /// The route check keeps a background audio session from holding the screen
  /// awake: [enterPip] and the audio page both leave the video route.
  bool get isPlayerPageForeground {
    final route = Get.currentRoute;
    return route == '/videoV' || route == '/liveRoom';
  }

  /// App lifecycle, routed through the controller instead of reaching into mpv.
  ///
  /// Distinguishes the user's pause from a system interruption: only a pause
  /// this method caused is resumed, and nothing resumes while PiP owns the
  /// picture.
  Future<void> handleAppLifecycle(AppLifecycleState state) async {
    if (_disposed) return;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _isForeground = false;
        _syncWakeLock();
        await _maybeAutoEnterPipOnBackground();
        if (continuePlayInBackground.value) return;
        if (Platform.isIOS && IOSPipHelper.isActive) return;
        if (_snapshot.playing) {
          _pausedForBackground = true;
          await pause(isInterrupt: true);
        }
      case AppLifecycleState.resumed:
        _isForeground = true;
        _syncWakeLock();
        final shouldResume = _pausedForBackground;
        _pausedForBackground = false;
        if (!shouldResume) return;
        if (Platform.isIOS && IOSPipHelper.isActive) return;
        await play(hideControls: false);
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        // A PiP transition and the control centre both pass through here; it is
        // not a reason to stop or restart anything.
        break;
    }
  }

  void _updatePlaybackState({Duration? position, String? debugLabel}) {
    final at = position ?? _snapshot.position;
    videoPlayerServiceHandler?.onUpdateState(
      playerStatus,
      isBuffering.value,
      isLive,
      position: at,
      speed: playbackSpeed,
      debugLabel: debugLabel,
    );
    _updateIOSPip(at);
  }

  /// 播放事件监听
  void _startListeners(NativePlayer player) {
    assert(_subscriptions == null);
    final stream = player.stream;
    _subscriptions = [
      /// playing
      stream.playing.listen((bool playing) {
        if (playing) {
          _stopWakeLockTimer();

          if (_isAutoEnterPip) {
            if (_isCurrVideoPage) {
              enterPip(autoEnter: true);
            } else {
              _disableAutoEnterPip();
            }
          }
        } else {
          _startWakeLockTimer();
          _disableAutoEnterPip();
        }

        _reduceMpv(playing: playing, completed: false, notifyStatus: true);

        if (playing) {
          final seconds = _snapshot.position.inSeconds;
          if (seconds != 0) {
            makeHeartBeat(seconds, type: .status);
          }
        }
      }),

      ///completed
      stream.completed.listen((bool completed) {
        if (completed) {
          _startWakeLockTimer();
          _reduceMpv(playing: false, completed: true, notifyStatus: true);
          makeHeartBeat(-1, type: .completed);
        }
      }),

      /// position
      stream.position.listen((Duration position) {
        final moved = position.inSeconds != _snapshot.position.inSeconds;
        _reduceMpv(
          position: position,
          // A position that jumps back to zero while still playing is a reload,
          // not a pause; the media centre has to be told.
          notifyStatus: false,
          debugLabel: moved && position.inSeconds == 0 ? 'positionReset' : null,
        );

        if (moved) {
          makeHeartBeat(position.inSeconds);
        }

        for (final element in _positionListeners) {
          element(position);
        }
      }),
      stream.duration.listen((Duration duration) {
        _reduceMpv(duration: duration);
      }),
      stream.buffer.listen((Duration buffer) {
        _reduceMpv(buffered: buffer);
      }),
      stream.buffering.listen((bool buffering) {
        if (!playerStatus.isCompleted) {
          _stopWakeLockTimer();
        }
        _reduceMpv(buffering: buffering);
      }),
      if (kDebugMode)
        stream.log.listen(((PlayerLog log) {
          if (log.level == 'error' || log.level == 'fatal') {
            Utils.reportError(
              '${log.level}: ${log.prefix}: ${log.text}\n${player.state.playlist}',
              null,
            );
          } else {
            debugPrint(log.toString());
          }
        })),
      stream.error.listen((String event) {
        if (dataSource is FileSource &&
            event.startsWith("Failed to open file")) {
          return;
        }
        if (isLive) {
          if (event.startsWith('tcp: ffurl_read returned ') ||
              event.startsWith("Failed to open https://") ||
              event.startsWith("Can not open external file https://")) {
            Timer(const Duration(milliseconds: 3000), refreshPlayer);
          }
          return;
        }
        if (event.startsWith("Failed to open https://") ||
            event.startsWith("Can not open external file https://") ||
            //tcp: ffurl_read returned 0xdfb9b0bb
            //tcp: ffurl_read returned 0xffffff99
            event.startsWith('tcp: ffurl_read returned ')) {
          EasyThrottle.throttle(
            'controllerStream.error.listen',
            const Duration(milliseconds: 10000),
            () => Timer(const Duration(milliseconds: 3000), () {
              // if (kDebugMode) {
              //   debugPrint("isBuffering.value: ${isBuffering.value}");
              // }
              // if (kDebugMode) {
              //   debugPrint("_buffered.value: ${_buffered.value}");
              // }
              if (isBuffering.value && buffered.value == 0) {
                SmartDialog.showToast(
                  '视频链接打开失败，重试中',
                  displayTime: const Duration(milliseconds: 500),
                );
                refreshPlayer();
              }
            }),
          );
        } else if (event.startsWith('Could not open codec')) {
          SmartDialog.showToast('无法加载解码器, $event，可能会切换至软解');
        } else if (!onlyPlayAudio.value) {
          if (event.startsWith("error running") ||
              event.startsWith("Failed to open .") ||
              event.startsWith("Cannot open") ||
              event.startsWith("Can not open")) {
            return;
          }
          if (!kDebugMode) {
            Utils.reportError('$event\n${player.state.playlist}');
          }
          // SmartDialog.showToast('视频加载错误, $event');
        }
      }),
    ];
  }

  /// Reduces one mpv event into the shared snapshot.
  ///
  /// This is the only place mpv state is allowed to become controller state;
  /// the native stream goes through [applySnapshot] the same way.
  void _reduceMpv({
    Duration? position,
    Duration? duration,
    Duration? buffered,
    bool? playing,
    bool? buffering,
    bool? completed,
    bool notifyStatus = false,
    String? debugLabel,
  }) {
    applySnapshot(
      _snapshot.copyWith(
        generation: generation,
        backend: PlaybackBackendKind.mpv,
        position: position,
        duration: duration,
        buffered: buffered,
        playing: playing,
        buffering: buffering,
        completed: completed,
      ),
      notifyStatus: notifyStatus,
      debugLabel: debugLabel,
    );
  }

  /// 移除事件监听
  void _removeListeners() {
    _subscriptions?.forEach((e) => e.cancel());
    _subscriptions?.clear();
    _subscriptions = null;
  }

  void _cancelSubForSeek() {
    if (_subForSeek != null) {
      _subForSeek!.cancel();
      _subForSeek = null;
    }
  }

  /// The only path a seek takes.
  ///
  /// It is clamped once, sent to the active backend only, and recorded in the
  /// snapshot so the progress bar cannot show an older position than the one
  /// just requested. A burst of drags ends with the last intent because the
  /// native side is told the newest target and mpv seeks to the same value.
  Future<void> seek(Duration position, {bool isSeek = false}) async {
    if (isSeek && !_isNativeActive) {
      /// 拖动进度条调节时，不等待第一帧，防止抖动
      try {
        await _videoPlayerController?.stream.buffer.first;
      } catch (_) {}
    }
    danmakuController?.clear();
    final clamped = _clampPosition(position);
    if (_isNativeActive) {
      try {
        await _nativeHost?.session?.seek(clamped);
        applySnapshot(_snapshot.copyWith(position: clamped));
      } catch (e) {
        if (kDebugMode) debugPrint('native seek failed: $e');
      }
      return;
    }
    try {
      await _videoPlayerController?.seek(clamped);
      applySnapshot(_snapshot.copyWith(position: clamped));
    } catch (e) {
      if (kDebugMode) debugPrint('seek failed: $e');
    }
  }

  Duration _clampPosition(Duration position) {
    if (position < Duration.zero) return Duration.zero;
    final total = _snapshot.duration;
    if (total > Duration.zero && position > total) return total;
    return position;
  }

  /// 跳转至指定位置
  Future<void> seekTo(Duration position, {bool isSeek = true}) async {
    if (_playerCount == 0) {
      return;
    }
    final target = _clampPosition(position);
    _heartDuration = target.inSeconds;

    if (_isNativeActive) {
      await seek(target, isSeek: false);
      return;
    }
    if (duration.value != 0) {
      await seek(target, isSeek: isSeek);
    } else {
      // The duration is not known yet; remember the target and apply it once
      // the duration arrives, instead of leaking a subscription per seek.
      _pendingSeekUntilDuration = target;
      _subForSeek?.cancel();
      _subForSeek = duration.listen((_) {
        final pending = _pendingSeekUntilDuration;
        _pendingSeekUntilDuration = null;
        _cancelSubForSeek();
        if (pending != null) seek(pending, isSeek: isSeek);
      });
    }
  }

  Duration? _pendingSeekUntilDuration;

  /// 设置倍速
  Future<void> setPlaybackSpeed(double speed) async {
    lastPlaybackSpeed = playbackSpeed;

    if (speed == _snapshot.rate) return;

    if (_isNativeActive) {
      await _nativeHost?.session?.setRate(speed);
    } else {
      await _videoPlayerController?.setRate(speed);
    }
    applySnapshot(_snapshot.copyWith(rate: speed));
    if (!isLive) _playbackSpeed.value = speed;
    _updatePlaybackState();
    if (danmakuController != null) {
      try {
        danmakuController?.updateOption(
          danmakuController!.option.copyWith(
            duration: DanmakuOptions.danmakuDuration / speed,
            staticDuration: DanmakuOptions.danmakuStaticDuration / speed,
          ),
        );
      } catch (_) {}
    }
  }

  /// 播放视频
  Future<void> play({bool repeat = false, bool hideControls = true}) async {
    if (_playerCount == 0) return;
    // 播放时自动隐藏控制条
    controls = !hideControls;
    // repeat为true，将从头播放
    if (repeat) {
      await seekTo(Duration.zero, isSeek: false);
    }

    if (_isNativeActive) {
      await _nativeHost?.session?.play();
    } else {
      await _videoPlayerController?.play();
    }
    applySnapshot(_snapshot.copyWith(playing: true, completed: false));

    audioSessionHandler?.setActive(true);

    playerStatus = .playing;
  }

  /// 暂停播放
  /// Non-null while a native AVPlayerLayer is drawing the picture.
  ///
  /// On that path mpv is not the player, so its play/pause/seek calls do
  /// nothing visible. Each control still goes through this controller, so the
  /// call is mirrored to the native surface here instead of at every button.
  Future<void> pause({bool notify = true, bool isInterrupt = false}) async {
    if (_isNativeActive) {
      await _nativeHost?.session?.pause();
    } else {
      await _videoPlayerController?.pause();
    }
    applySnapshot(_snapshot.copyWith(playing: false));
    playerStatus = .paused;

    // 主动暂停时让出音频焦点
    if (!isInterrupt) {
      audioSessionHandler?.setActive(false);
    }
  }

  bool tripling = false;

  /// 隐藏控制条
  void hideTaskControls() {
    _timer?.cancel();
    _timer = Timer(showControlDuration, () {
      if (!isSeeking.value && !tripling && hoverDx == null) {
        controls = false;
      }
      _timer = null;
    });
  }

  void onSeekStart(int seekFrom) {
    seekPosition.value = seekFrom;
    isSeeking.value = true;
  }

  void onSeekEnd() {
    if (showSeekPreview) {
      showPreview.value = false;
    }
    hasToasted = false;
    isSeeking.value = false;
    hideTaskControls();
  }

  final RxBool volumeIndicator = false.obs;
  Timer? volumeTimer;
  bool volumeInterceptEventStream = false;

  final double maxVolume = PlatformUtils.isDesktop ? Pref.maxVolume : 1.0;
  Future<void> setVolume(double volume, {bool showIndicator = true}) async {
    if (this.volume.value != volume) {
      this.volume.value = volume;
      try {
        if (PlatformUtils.isDesktop) {
          await _videoPlayerController!.setVolume(volume * 100);
        } else {
          FlutterVolumeController.updateShowSystemUI(false);
          await FlutterVolumeController.setVolume(volume);
        }
      } catch (err) {
        if (kDebugMode) debugPrint(err.toString());
      }
    }
    if (showIndicator) {
      volumeIndicator.value = true;
    }
    volumeInterceptEventStream = true;
    volumeTimer?.cancel();
    volumeTimer = Timer(const Duration(milliseconds: 200), () {
      volumeIndicator.value = false;
      volumeInterceptEventStream = false;
      if (PlatformUtils.isDesktop) {
        setting.put(SettingBoxKey.desktopVolume, volume.toPrecision(3));
      }
    });
  }

  /// Toggle Change the videofit accordingly
  void toggleVideoFit(VideoFitType value) {
    _prefFit = videoFit.value = value;
    video.put(VideoBoxKey.cacheVideoFit, value.index);
  }

  /// 读取fit
  var _prefFit = VideoFitType.values[Pref.cacheVideoFit];
  void _initVideoFit() {
    if (_prefFit == .fill && _isVertical) {
      videoFit.value = .contain;
    } else {
      videoFit.value = _prefFit;
    }
  }

  /// 设置后台播放
  void setBackgroundPlay(bool val) {
    videoPlayerServiceHandler?.enableBackgroundPlay = val;
    if (!tempPlayerConf) {
      setting.put(SettingBoxKey.enableBackgroundPlay, val);
    }
  }

  set controls(bool visible) {
    showControls.value = visible;
    _timer?.cancel();
    if (visible) {
      hideTaskControls();
    }
  }

  Timer? longPressTimer;
  void cancelLongPressTimer() {
    longPressTimer?.cancel();
    longPressTimer = null;
  }

  /// 设置长按倍速状态 live模式下禁用
  Future<void> setLongPressStatus(bool val) async {
    if (isLive) {
      return;
    }
    if (controlsLock.value) {
      return;
    }
    if (longPressStatus.value == val) {
      return;
    }
    if (val) {
      if (playerStatus.isPlaying) {
        longPressStatus.value = val;
        HapticFeedback.lightImpact();
        await setPlaybackSpeed(
          enableAutoLongPressSpeed ? playbackSpeed * 2 : longPressSpeed,
        );
      }
    } else {
      // if (kDebugMode) debugPrint('$playbackSpeed');
      longPressStatus.value = val;
      await setPlaybackSpeed(lastPlaybackSpeed);
    }
  }

  bool get isCompleted =>
      _snapshot.completed ||
      (durationInMilliseconds > 0 &&
          durationInMilliseconds - positionInMilliseconds <= 50);

  // 双击播放、暂停
  Future<void> onDoubleTapCenter() async {
    if (!isLive && isCompleted) {
      await seek(Duration.zero, isSeek: false);
      await play();
      return;
    }
    // Routed through the facade so the active backend is the one that moves.
    if (playerStatus.isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  final RxBool mountSeekBackwardButton = false.obs;
  final RxBool mountSeekForwardButton = false.obs;

  void onDoubleTapSeekBackward() {
    mountSeekBackwardButton.value = true;
  }

  void onDoubleTapSeekForward() {
    mountSeekForwardButton.value = true;
  }

  void onForward(Duration duration) {
    onForwardBackward(_snapshot.position + duration);
  }

  void onBackward(Duration duration) {
    onForwardBackward(_snapshot.position - duration);
  }

  void multiBackwardStart([_]) {
    isSeeking.value = true;
    seekPosition.value = max(0, seekPosition.value - fastForBackwardInSeconds);
  }

  void multiBackwardEnd() {
    if (isSeeking.value) {
      isSeeking.value = false;
      onForwardBackward(Duration(seconds: seekPosition.value));
    } else {
      onBackward(fastForBackwardDuration);
    }
  }

  void onForwardBackward(Duration duration) {
    final total = _snapshot.duration;
    final target = total > Duration.zero
        ? duration.clamp(Duration.zero, total)
        : (duration < Duration.zero ? Duration.zero : duration);
    seekTo(target, isSeek: false).whenComplete(play);
  }

  void doubleTapFuc(DoubleTapType type) {
    if (!enableQuickDouble) {
      onDoubleTapCenter();
      return;
    }
    switch (type) {
      case DoubleTapType.left:
        // 双击左边区域 👈
        onDoubleTapSeekBackward();
        break;
      case DoubleTapType.center:
        onDoubleTapCenter();
        break;
      case DoubleTapType.right:
        // 双击右边区域 👈
        onDoubleTapSeekForward();
        break;
    }
  }

  /// 关闭控制栏
  void onLockControl(bool val) {
    feedBack();
    controlsLock.value = val;
    if (!val && showControls.value) {
      showControls.refresh();
    }
    controls = !val;
  }

  void _setFullScreen(bool val) {
    isFullScreen.value = val;
    updateSubtitleStyle();
  }

  double screenRatio = 0.0;
  bool isManualFS = true;
  late final FullScreenMode mode = Pref.fullScreenMode;
  late final horizontalScreen = Pref.horizontalScreen;
  late final removeSafeArea = Pref.removeSafeArea;

  Future<void>? changeOrientation({
    required bool isVertical,
    DeviceOrientation? orientation,
  }) {
    if (orientation == null && (mode == .none || mode == .gravity)) {
      return null;
    }
    if (orientation == null &&
        (mode == .vertical ||
            (mode == .auto && isVertical) ||
            (mode == .ratio && (isVertical || screenRatio < kScreenRatio)))) {
      return portraitUpMode();
    } else {
      // https://github.com/flutter/flutter/issues/73651
      // https://github.com/flutter/flutter/issues/183708
      if (Platform.isAndroid) {
        if ((orientation ?? _orientation) == .landscapeRight) {
          return landscapeRightMode();
        } else {
          return landscapeLeftMode();
        }
      } else {
        if (orientation == .landscapeLeft) {
          return landscapeLeftMode();
        } else {
          return landscapeRightMode();
        }
      }
    }
  }

  // 全屏
  bool _fsProcessing = false;
  Future<void> triggerFullScreen({
    bool status = true,
    bool inAppFullScreen = false,
    DeviceOrientation? orientation,
    bool isManualFS = true,
  }) async {
    if (isDesktopPip) return;
    if (isFullScreen.value == status) return;

    if (_fsProcessing) return;
    _fsProcessing = true;
    this.isManualFS = isManualFS;
    try {
      if (status) {
        if (PlatformUtils.isMobile) {
          hideSystemBar();
          await changeOrientation(
            isVertical: isVertical,
            orientation: orientation,
          );
        } else {
          enterDesktopFullScreen(inAppFullScreen: inAppFullScreen);
        }
      } else {
        if (PlatformUtils.isMobile) {
          if (!removeSafeArea) {
            showSystemBar();
          }
          if (orientation == null && mode == .none) {
            return;
          }
          await resetScreenRotation();
        } else {
          exitDesktopFullScreen();
        }
      }
    } finally {
      _setFullScreen(status);
      _fsProcessing = false;
    }
  }

  void addPositionListener(ValueChanged<Duration> listener) {
    if (_playerCount == 0) return;
    _positionListeners.add(listener);
  }

  void removePositionListener(ValueChanged<Duration> listener) =>
      _positionListeners.remove(listener);

  void addStatusLister(ValueChanged<PlayerStatus> listener) {
    if (_playerCount == 0) return;
    _statusListeners.add(listener);
  }

  void removeStatusLister(ValueChanged<PlayerStatus> listener) =>
      _statusListeners.remove(listener);

  // 记录播放记录
  Future<void>? makeHeartBeat(
    int progress, {
    HeartBeatType type = .playing,
    bool isManual = false,
    dynamic aid,
    dynamic bvid,
    dynamic cid,
    dynamic epid,
    dynamic seasonId,
    dynamic pgcType,
    VideoType? videoType,
  }) {
    if (isLive ||
        !enableHeart ||
        progress == 0 ||
        (playerStatus.isPaused && !isManual)) {
      return null;
    }

    Future<void> send() {
      return VideoHttp.heartBeat(
        aid: aid ?? _aid,
        bvid: bvid ?? _bvid,
        cid: cid ?? this.cid,
        progress: progress,
        epid: epid ?? _epid,
        seasonId: seasonId ?? _seasonId,
        subType: pgcType ?? _pgcType,
        videoType: videoType ?? _videoType,
      );
    }

    switch (type) {
      case .playing:
        if (progress - _heartDuration >= 5) {
          _heartDuration = progress;
          return send();
        }
      case .status:
        if (progress - _heartDuration >= 2) {
          _heartDuration = progress;
          return send();
        }
      case .completed:
        if (playerStatus.isCompleted &&
            (durationInMilliseconds - positionInMilliseconds) <= 1000) {
          progress = -1;
        }
        return send();
    }
    return null;
  }

  void setPlayRepeat(PlayRepeat type) {
    playRepeat = type;
    if (!tempPlayerConf) video.put(VideoBoxKey.playRepeat, type.index);
  }

  void putSubtitleSettings() {
    setting.putAllNE({
      SettingBoxKey.subtitleFontScale: subtitleFontScale,
      SettingBoxKey.subtitleFontScaleFS: subtitleFontScaleFS,
      SettingBoxKey.subtitlePaddingH: subtitlePaddingH,
      SettingBoxKey.subtitlePaddingB: subtitlePaddingB,
      SettingBoxKey.subtitleBgOpacity: subtitleBgOpacity,
      SettingBoxKey.subtitleStrokeWidth: subtitleStrokeWidth,
      SettingBoxKey.subtitleFontWeight: subtitleFontWeight,
    });
  }

  bool _isCloseAll = false;
  bool get isCloseAll => _isCloseAll;

  Future<void>? resetScreenRotation() {
    if (horizontalScreen) {
      return fullMode();
    } else {
      return portraitUpMode();
    }
  }

  void onCloseAll() {
    _isCloseAll = true;
    if (PlatformUtils.isDesktop) exitDesktopFullScreen();
    dispose();
    Get.until((route) => route.isFirst);
  }

  void dispose() {
    // 每次减1，最后销毁
    resetScreenRotation();
    cancelLongPressTimer();
    _cancelSubForSeek();
    if (!_isCloseAll && _playerCount > 1) {
      _playerCount -= 1;
      _heartDuration = 0;
      return;
    }

    _playerCount = 0;
    if (removeSafeArea) {
      showSystemBar();
    }
    danmakuController = null;
    _stopOrientationListener();
    _disableAutoEnterPip();
    setPlayCallBack(null);
    dmState.clear();
    if (showSeekPreview) {
      _clearPreview();
    }
    if (Platform.isAndroid) {
      AndroidHelper$ToDart.onUserLeaveHint = null;
    } else if (Platform.isIOS) {
      IOSPipHelper.dispose();
    }
    _timer?.cancel();
    // _position.close();
    // _playerEventSubs?.cancel();
    // _sliderPosition.close();
    // _sliderTempPosition.close();
    // _isSliderMoving.close();
    // _duration.close();
    // _buffered.close();
    // _showControls.close();
    // _controlsLock.close();

    // playerStatus.close();
    // dataStatus.close();

    if (PlatformUtils.isDesktop && isAlwaysOnTop.value) {
      WindowController.instance.window?.isAlwaysOnTop = false;
    }

    _removeListeners();
    // The native session owns a player, a layer and temporary files; leaving it
    // to the widget meant a force-quit or an out-of-order teardown leaked them.
    _disposed = true;
    _routing = PlaybackRoute.disposed;
    closeNativeHdr();
    _positionListeners.clear();
    _statusListeners.clear();
    _stopWakeLockTimer();
    _disableWakeLock();
    _nativePip?.dispose();
    _nativePip = null;
    if (kDebugMode) {
      debugPrint('dispose player');
    }
    _videoPlayerController?.dispose();
    _videoPlayerController = null;
    _videoController = null;
    _instance = null;
    videoPlayerServiceHandler?.clear();
  }

  static void updatePlayCount() {
    if (_instance?._playerCount == 1) {
      _instance?.dispose();
    } else {
      _instance?._playerCount -= 1;
    }
  }

  void setContinuePlayInBackground() {
    continuePlayInBackground.toggle();
    if (!tempPlayerConf) {
      setting.put(
        SettingBoxKey.continuePlayInBackground,
        continuePlayInBackground.value,
      );
    }
  }

  late final Map<String, ui.Image?> previewCache = {};
  LoadingState<VideoShotData>? videoShot;
  double? hoverDx;
  late final RxBool showPreview = false.obs;
  late final showSeekPreview = Pref.showSeekPreview;
  late final previewIndex = RxnInt();

  void updatePreviewIndex(int seconds) {
    if (videoShot == null) {
      videoShot = LoadingState.loading();
      getVideoShot();
      return;
    }
    if (videoShot case Success(:final response)) {
      showPreview.value = true;
      final index = max(
        0,
        (response.index.where((item) => item <= seconds).length - 2),
      );
      if (previewIndex.value != index) {
        previewIndex.value = index;
      } else if (hoverDx != null) {
        previewIndex.refresh();
      }
    }
  }

  void _clearPreview() {
    showPreview.value = false;
    previewIndex.value = null;
    videoShot = null;
    for (final i in previewCache.values) {
      i?.dispose();
    }
    previewCache.clear();
  }

  Future<void> getVideoShot() async {
    videoShot = await VideoHttp.videoshot(bvid: bvid, cid: cid!);
  }

  int _screenshotState = 0;

  /// One captured frame, encoded and released before it is returned.
  ///
  /// The caller owns the bytes only; the `ui.Image` is disposed here so the
  /// reply editor and the save dialog cannot leak a full-resolution buffer.
  Future<({Uint8List png, int width, int height})?> captureFrame() async {
    // Native path: the frame comes from the running AVPlayerItem, never from a
    // second download and never from a Flutter RepaintBoundary (which cannot
    // see a platform view's contents).
    if (route.isNative) {
      final sessionId = _nativeHost?.openedSessionId;
      if (sessionId == null || !capabilities.nativeScreenshot) return null;
      final frame = await NativeFrameCapture.capture(sessionId);
      if (frame == null) return null;
      return (png: frame.png, width: frame.width, height: frame.height);
    }
    if (!capabilities.screenshot) return null;
    final player = _videoPlayerController;
    if (player == null) return null;
    ui.Image? image;
    try {
      image = await player.screenshot();
      if (image == null) return null;
      final data = await image.toByteData(format: .png);
      if (data == null) return null;
      return (
        png: data.buffer.asUint8List(),
        width: image.width,
        height: image.height,
      );
    } catch (err) {
      if (kDebugMode) debugPrint('captureFrame failed: $err');
      return null;
    } finally {
      image?.dispose();
    }
  }

  /// Grabs the current frame, or explains precisely why it cannot.
  ///
  /// Every entry point - the full-screen button, the S key, the reply editor -
  /// goes through here so the capability check happens once. The state flag is
  /// restored in a `finally` and the image is disposed even when the dialog is
  /// dismissed by a route pop, which used to leak the buffer.
  ///
  /// Returns `true` when the frame was shown. On the native path the answer is
  /// an explicit refusal, not a generic "screenshot failed": the user has to be
  /// able to tell a missing feature from a broken one.
  Future<bool> takeScreenshot() async {
    if (_screenshotState > 0) return false;
    if (!capabilities.screenshot) {
      _toast(capabilities.unsupportedReason('截图', route));
      return false;
    }
    final player = _videoPlayerController;
    if (player == null) {
      _toast(capabilities.unsupportedReason('截图', route));
      return false;
    }
    _screenshotState = 1;
    ui.Image? image;
    try {
      SmartDialog.showToast('截图中');
      try {
        image = await player.screenshot();
      } catch (err) {
        if (kDebugMode) debugPrint('screenshot failed: $err');
        image = null;
      }
      if (image == null) {
        SmartDialog.showToast(
          route.isMpv ? '截图失败' : capabilities.unsupportedReason('截图', route),
        );
        return false;
      }
      if (_disposed) return false;
      SmartDialog.showToast('点击弹窗或按 Enter 保存截图');
      final captured = image;
      await showDialog(
        context: Get.context!,
        requestFocus: true,
        builder: (context) {
          Future<void> save() async {
            if (_screenshotState > 1) return;
            _screenshotState = 2;
            final bytes = await captured.toByteData(format: .png);
            if (bytes != null) {
              final time = DurationUtils.formatDuration(
                positionInMilliseconds / 1000,
              ).replaceAll(':', '-');
              ImageUtils.saveByteImg(
                bytes: bytes.buffer.asUint8List(),
                fileName: 'screenshot_${cid}_$time',
              );
            } else {
              SmartDialog.showToast('保存失败');
            }
            Get.back();
          }

          return Focus(
            autofocus: true,
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent) {
                final key = event.logicalKey;
                if (key == .keyS || key == .enter || key == .numpadEnter) {
                  save();
                  return .handled;
                }
              }
              return .ignored;
            },
            child: GestureDetector(
              onTap: save,
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: min(MediaQuery.widthOf(context) / 3, 350),
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(
                          width: 5,
                          color: ColorScheme.of(context).surface,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(5),
                        child: RawImage(image: captured),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
      return true;
    } finally {
      image?.dispose();
      _screenshotState = 0;
    }
  }

  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (didPop) {
      if (playerStatus.isPlaying) {
        pause();
      }

      setPlayCallBack(null);

      if (Platform.isAndroid && _playerCount <= 1) {
        _disableAutoEnterPip();
        if (!setSystemBrightness) {
          ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
        }
      }

      return;
    }

    if (controlsLock.value) {
      onLockControl(false);
      return;
    }
    if (isDesktopPip) {
      exitDesktopPip();
      return;
    }
    if (isFullScreen.value) {
      triggerFullScreen(status: false);
      return;
    }
    Get.back();
  }
}
