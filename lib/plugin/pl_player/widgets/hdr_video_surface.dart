import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/backend/playback_backend.dart';
import 'package:PiliPlus/plugin/pl_player/backend/playback_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// What the native layer reports it is presenting.
///
/// This is diagnostic output, not the state channel: playback state reaches the
/// UI through [PlaybackSnapshot] so a stalled picture and a paused one are not
/// inferred from an occasional poll.
///
/// Three questions stay separate here, because collapsing them is what let a
/// HEVC Main10 SDR clip be labelled "confirmed HDR":
///
///  * what the media is - [transferFunction], [primaries], [bitDepth],
///    [dolbyVision];
///  * what the path can do - [eligibleForHdrPlayback], [edrRequested];
///  * what the screen shows - [hdrPresented], which no public API can assert.
@immutable
class HdrPlaybackInfo {
  const HdrPlaybackInfo({
    this.hdr,
    this.edrRequested = false,
    this.primaries,
    this.transfer,
    this.transferFunction,
    this.matrix,
    this.codec,
    this.bitDepth,
    this.dolbyVision,
    this.width = 0,
    this.height = 0,
    this.source = '',
    this.audio = '',
    this.rate = 0,
    this.seconds = 0,
    this.ready = false,
  });

  /// True (HDR), false (the track says SDR), or null (unknown).
  ///
  /// Null is not "false": a missing descriptor is not evidence of SDR, and the
  /// panel has to be able to say 检测中 instead of inventing an answer.
  final bool? hdr;

  /// The layer was told to composite extended range. A request, not a result.
  final bool edrRequested;

  final String? primaries;
  final String? transfer;

  /// Normalised transfer function: PQ, HLG, SDR, or null when unknown.
  final String? transferFunction;

  final String? matrix;
  final String? codec;
  final int? bitDepth;
  final Map<Object?, Object?>? dolbyVision;

  final int width;
  final int height;

  /// How the media was adapted, e.g. `hls-fmp4 segments=812`.
  final String source;

  /// What happened to the DASH audio track.
  final String audio;

  final double rate;
  final double seconds;
  final bool ready;

  bool get isReady => ready;

  /// What to display for the source dynamic range.
  ///
  /// 未知 is a real answer here; the panel must not claim SDR for a stream it
  /// has no metadata for.
  String get dynamicRangeLabel {
    if (dolbyVision != null) return 'Dolby Vision';
    return switch (transferFunction) {
      'PQ' => 'HDR10',
      'HLG' => 'HLG',
      'SDR' => 'SDR',
      _ => hdr == true ? 'HDR' : (hdr == false ? 'SDR' : '未知'),
    };
  }

  factory HdrPlaybackInfo.fromMap(Map<Object?, Object?> map) => HdrPlaybackInfo(
    // Absent stays null; false is a statement the track made.
    hdr: map['hdr'] as bool?,
    edrRequested: map['edrRequested'] == true,
    primaries: map['primaries'] as String?,
    transfer: map['transfer'] as String?,
    transferFunction: map['transferFunction'] as String?,
    matrix: map['matrix'] as String?,
    codec: map['codec'] as String?,
    bitDepth: (map['bitDepth'] as num?)?.toInt(),
    dolbyVision: map['dolbyVision'] as Map?,
    width: ((map['codedWidth'] ?? map['width']) as num?)?.toInt() ?? 0,
    height: ((map['codedHeight'] ?? map['height']) as num?)?.toInt() ?? 0,
    source: map['source'] as String? ?? '',
    audio: map['audio'] as String? ?? '',
    rate: (map['rate'] as num?)?.toDouble() ?? 0,
    seconds: (map['seconds'] as num?)?.toDouble() ?? 0,
    ready: map['ready'] == true,
  );

  @override
  String toString() =>
      'hdr=${hdr ?? 'unknown'} edr=$edrRequested '
      'tf=${transferFunction ?? '-'} ${width}x$height src=$source';
}

/// A video surface backed by AVPlayerLayer instead of mpv.
///
/// The surface is only a view. The player, its audio track and its lifetime
/// belong to the controller's session; this widget attaches to the session
/// named in its key and disposes nothing it does not own.
class HdrVideoSurface extends StatefulWidget {
  const HdrVideoSurface({
    super.key,
    required this.sessionId,
    required this.url,
    this.audioUrl,
    this.autoPlay = true,
    this.onReady,
  });

  /// The business session this view renders. Stable across rebuilds.
  final String sessionId;

  /// Where the session is playing. The view only *attaches* to the session the
  /// controller created; passing the URL is what lets the native side recover
  /// if the session was created before the surface existed.
  final String url;
  final String? audioUrl;

  final bool autoPlay;

  /// Diagnostic description, emitted at a low rate.
  final ValueChanged<HdrPlaybackInfo>? onReady;

  /// Whether the platform can host this at all.
  static bool get isSupported => defaultTargetPlatform == TargetPlatform.iOS;

  @override
  State<HdrVideoSurface> createState() => _HdrVideoSurfaceState();
}

class _HdrVideoSurfaceState extends State<HdrVideoSurface> {
  static const _viewType = 'pilipilus/hdr_video';
  static const _control = MethodChannel('pilipilus/hdr_video/control');

  int? _viewId;
  Timer? _describeTimer;

  @override
  void initState() {
    super.initState();
    // One low-rate description for the UI badge. Playback state does not come
    // from here, so stopping it would not stop updates; it is bounded because
    // it only feeds a label.
    _describeTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _describe();
    });
  }

  Future<void> _describe() async {
    final id = _viewId;
    if (id == null || widget.onReady == null) return;
    try {
      final info = await _control.invokeMethod<Map>('describe', {'id': id});
      if (!mounted || info == null) return;
      widget.onReady!(HdrPlaybackInfo.fromMap(info));
    } catch (_) {
      // The session may have been replaced; the next tick retries.
    }
  }

  @override
  void dispose() {
    _describeTimer?.cancel();
    _describeTimer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!HdrVideoSurface.isSupported) {
      return const SizedBox.shrink();
    }
    return UiKitView(
      viewType: _viewType,
      // The surface is a picture, not a control: every touch has to reach the
      // Flutter gestures layered above it (tap to toggle the controls, drag to
      // seek, pinch to zoom).
      //
      // The default is `opaque`, which marks the whole platform-view area as
      // consuming hits. That is why the progress bar could not be summoned while
      // an HDR video played: the tap landed on the AVPlayerLayer's area and the
      // Flutter tap recognizer never saw it. `transparent` does not change what
      // is drawn - it only stops the layer from claiming the pointer.
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      // The view joins an existing session; it never creates one, so a rebuild
      // cannot restart the stream.
      creationParams: {
        'sessionId': widget.sessionId,
        'url': widget.url,
        'audioUrl': widget.audioUrl,
      },
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: (id) {
        _viewId = id;
        if (widget.autoPlay) {
          _control
              .invokeMethod<void>('play', {'id': id})
              .catchError((Object _) {});
        }
      },
    );
  }
}

/// Binds a [PlaybackSession] to a platform view id.
///
/// Kept separate from the widget so tests can exercise the wiring without a
/// platform view.
abstract final class NativeSurfaceBinding {
  static PlaybackBackendKind kindOf(PlaybackSnapshot snapshot) =>
      snapshot.backend;
}