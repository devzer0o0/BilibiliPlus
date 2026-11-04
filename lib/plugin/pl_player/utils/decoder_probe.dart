import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// Decoder/output counters read from the *running* mpv, for measurement only.
///
/// `hwdec=videotoolbox` plus `hwdec-codecs=all` is a request, not evidence: it
/// says what mpv was asked to do. These reads say what it did. They are gated on
/// [enabled] (a test/profile build switch) because a periodic property poll on
/// the wrong thread is itself a way to lose frames.
///
/// Missing properties are reported as `unavailable`, never as 0: "this libmpv
/// does not expose `decoder-frame-drop-count`" and "no frames were dropped" are
/// different facts, and conflating them is how a stutter gets signed off.
@immutable
class DecoderObservation {
  const DecoderObservation({
    this.hwdecCurrent,
    this.videoCodec,
    this.videoFormat,
    this.sourceWidth,
    this.sourceHeight,
    this.outputWidth,
    this.outputHeight,
    this.sourceFrameRate,
    this.estimatedFrameRate,
    this.frameDropCount,
    this.decoderFrameDropCount,
    this.avsyncSeconds,
    this.demuxerCacheDuration,
    this.pausedForCache,
    this.cacheSpeed,
    this.videoSync,
    this.at,
  });

  final String? hwdecCurrent;
  final String? videoCodec;
  final String? videoFormat;
  final int? sourceWidth;
  final int? sourceHeight;
  final int? outputWidth;
  final int? outputHeight;
  final double? sourceFrameRate;
  final double? estimatedFrameRate;

  /// Cumulative counters. A measurement takes the delta between two reads.
  final int? frameDropCount;
  final int? decoderFrameDropCount;

  final double? avsyncSeconds;
  final double? demuxerCacheDuration;
  final bool? pausedForCache;
  final double? cacheSpeed;
  final String? videoSync;
  final DateTime? at;

  bool get hardwareDecoding =>
      hwdecCurrent != null && hwdecCurrent != 'no' && hwdecCurrent != '';

  /// Software fallback with a name attached, instead of a guess.
  bool get softwareDecoding =>
      hwdecCurrent == 'no' || hwdecCurrent == '';

  /// The properties this libmpv actually answered.
  Set<String> get available => {
    if (hwdecCurrent != null) 'hwdec-current',
    if (videoCodec != null) 'video-codec',
    if (videoFormat != null) 'video-format',
    if (sourceWidth != null) 'width',
    if (sourceHeight != null) 'height',
    if (sourceFrameRate != null) 'container-fps',
    if (estimatedFrameRate != null) 'estimated-vf-fps',
    if (frameDropCount != null) 'frame-drop-count',
    if (decoderFrameDropCount != null) 'decoder-frame-drop-count',
    if (avsyncSeconds != null) 'avsync',
    if (demuxerCacheDuration != null) 'demuxer-cache-duration',
    if (pausedForCache != null) 'paused-for-cache',
    if (cacheSpeed != null) 'cache-speed',
    if (videoSync != null) 'video-sync',
  };

  /// Which of the interesting properties this build cannot report.
  List<String> get unavailable {
    const wanted = [
      'hwdec-current',
      'video-codec',
      'frame-drop-count',
      'decoder-frame-drop-count',
      'avsync',
      'demuxer-cache-duration',
      'paused-for-cache',
    ];
    return wanted.where((k) => !available.contains(k)).toList();
  }

  /// Deltas between two reads of the same playback.
  ///
  /// A cumulative counter read twice is not a rate; adding the second read to
  /// the first is how a "12 dropped frames" figure becomes meaningless.
  DecoderObservation deltaFrom(DecoderObservation previous) {
    int? diff(int? now, int? before) =>
        (now == null || before == null) ? null : (now - before);
    return DecoderObservation(
      hwdecCurrent: hwdecCurrent,
      videoCodec: videoCodec,
      videoFormat: videoFormat,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      outputWidth: outputWidth,
      outputHeight: outputHeight,
      sourceFrameRate: sourceFrameRate,
      estimatedFrameRate: estimatedFrameRate,
      frameDropCount: diff(frameDropCount, previous.frameDropCount),
      decoderFrameDropCount: diff(
        decoderFrameDropCount,
        previous.decoderFrameDropCount,
      ),
      avsyncSeconds: avsyncSeconds,
      demuxerCacheDuration: demuxerCacheDuration,
      pausedForCache: pausedForCache,
      cacheSpeed: cacheSpeed,
      videoSync: videoSync,
      at: at,
    );
  }

  @override
  String toString() =>
      'DecoderObservation(hwdec=${hwdecCurrent ?? 'unavailable'} '
      'codec=${videoCodec ?? '-'} '
      'src=${sourceWidth ?? '?'}x${sourceHeight ?? '?'} '
      'out=${outputWidth ?? '?'}x${outputHeight ?? '?'} '
      'fps=${sourceFrameRate ?? '?'} drops=${frameDropCount ?? '?'} '
      'decDrops=${decoderFrameDropCount ?? '?'} avsync=${avsyncSeconds ?? '?'} '
      'unavailable=$unavailable)';
}

/// Reads [DecoderObservation] from a live mpv player.
class DecoderProbe {
  DecoderProbe(this._player, {this.enabled = false});

  final Player _player;

  /// Off in a shipping build: this polls properties, which costs frames.
  final bool enabled;

  String? _raw(String property) {
    try {
      final value = _player.getProperty(property);
      return value.isEmpty ? null : value;
    } catch (_) {
      // Property absent in this libmpv build: report unavailable, not zero.
      return null;
    }
  }

  int? _int(String property) => int.tryParse(_raw(property) ?? '');

  double? _double(String property) => double.tryParse(_raw(property) ?? '');

  DecoderObservation sample() {
    if (!enabled) return const DecoderObservation();
    final paused = _raw('paused-for-cache');
    return DecoderObservation(
      hwdecCurrent: _raw('hwdec-current'),
      videoCodec: _raw('video-codec'),
      videoFormat: _raw('video-format'),
      sourceWidth: _int('width'),
      sourceHeight: _int('height'),
      outputWidth: _int('dw'),
      outputHeight: _int('dh'),
      sourceFrameRate: _double('container-fps'),
      estimatedFrameRate: _double('estimated-vf-fps'),
      frameDropCount: _int('frame-drop-count'),
      decoderFrameDropCount: _int('decoder-frame-drop-count'),
      avsyncSeconds: _double('avsync'),
      demuxerCacheDuration: _double('demuxer-cache-duration'),
      pausedForCache: paused == null ? null : paused == 'yes',
      cacheSpeed: _double('cache-speed'),
      videoSync: _raw('video-sync'),
      at: DateTime.now(),
    );
  }
}
