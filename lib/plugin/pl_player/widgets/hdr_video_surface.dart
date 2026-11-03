import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Mirrors what the native `AVPlayerLayer` is presenting.
@immutable
class HdrPlaybackInfo {
  const HdrPlaybackInfo({
    this.hdr = false,
    this.edrRequested = false,
    this.primaries,
    this.transfer,
    this.width = 0,
    this.height = 0,
    this.source = '',
    this.audio = '',
    this.ready = false,
  });

  final bool hdr;
  final bool edrRequested;
  final String? primaries;
  final String? transfer;
  final int width;
  final int height;

  /// What the native loader fetched.
  final String source;

  /// What happened to the DASH audio track.
  final String audio;

  /// Whether AVPlayerItem reported readyToPlay.
  final bool ready;

  factory HdrPlaybackInfo.fromMap(Map<Object?, Object?> map) => HdrPlaybackInfo(
    hdr: map['hdr'] == true,
    edrRequested: map['edrRequested'] == true,
    primaries: map['primaries'] as String?,
    transfer: map['transfer'] as String?,
    width: (map['width'] as num?)?.toInt() ?? 0,
    height: (map['height'] as num?)?.toInt() ?? 0,
    source: map['source'] as String? ?? '',
    audio: map['audio'] as String? ?? '',
    ready: map['ready'] == true,
  );

  @override
  String toString() =>
      'hdr=$hdr edr=$edrRequested ${primaries ?? '-'}/${transfer ?? '-'} '
      '${width}x$height src=$source';
}

/// A video surface backed by AVPlayerLayer instead of mpv.
///
/// Used only for 10-bit HDR renditions: mpv draws into an 8-bit BGRA Flutter
/// texture, which cannot carry extended range, so HDR is handed to the platform
/// player. SDR playback stays on mpv, where danmaku, subtitles and the quality
/// ladder already work.
class HdrVideoSurface extends StatefulWidget {
  const HdrVideoSurface({
    super.key,
    required this.url,
    this.audioUrl,
    this.autoPlay = true,
    this.onReady,
  });

  /// The rendition URL. A DASH segment URL plays only its own fragment, so
  /// callers should prefer a full-file or HLS URL where one is available.
  final String url;

  /// bilibili serves DASH audio as its own track; without it the picture is silent.
  final String? audioUrl;
  final bool autoPlay;
  final ValueChanged<HdrPlaybackInfo>? onReady;

  /// Whether the platform can host this at all. The texture path remains the
  /// fallback everywhere else.
  static bool get isSupported => defaultTargetPlatform == TargetPlatform.iOS;

  @override
  State<HdrVideoSurface> createState() => _HdrVideoSurfaceState();
}

class _HdrVideoSurfaceState extends State<HdrVideoSurface> {
  static const _viewType = 'pilipilus/hdr_video';
  static const _control = MethodChannel('pilipilus/hdr_video/control');

  int? _id;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final info = await _control.invokeMethod<Map>(
        'describe',
        // The controller is created by the platform view; give it a beat.
        {'id': _id ?? -1},
      );
      if (!mounted) return;
      if (info != null && widget.onReady != null) {
        widget.onReady!(HdrPlaybackInfo.fromMap(info));
      }
    } catch (_) {
      // Before the view exists there is no controller; that is expected.
    }
  }


  Future<void> _poll(int id) async {
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      try {
        final info = await _control.invokeMethod<Map>('describe', {'id': id});
        if (info == null || !mounted) continue;
        final parsed = HdrPlaybackInfo.fromMap(info);
        widget.onReady?.call(parsed);
        if (parsed.ready) return;
      } catch (_) {
        if (mounted) setState(() => _failed = true);
        return;
      }
    }
  }

  @override
  void dispose() {
    final id = _id;
    if (id != null) {
      _control.invokeMethod('dispose', {'id': id}).catchError((_) => null);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!HdrVideoSurface.isSupported) {
      return const SizedBox.shrink();
    }
    return UiKitView(
      viewType: _viewType,
      creationParams: {'url': widget.url, 'audioUrl': widget.audioUrl},
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: (id) {
        _id = id;
        if (widget.autoPlay) {
          _control.invokeMethod('play', {'id': id}).catchError((_) => null);
        }
        // Poll rather than read once: assembling twelve fragments takes longer
        // than any fixed delay that would also feel responsive, and the first
        // read always lands before the file exists.
        _poll(id);
      },
    );
  }

  bool get failed => _failed;
}
