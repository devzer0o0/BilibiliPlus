import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/video/play/url.dart'
    show VideoItem, FormatItem;
import 'package:flutter/foundation.dart';

/// The rendition that will actually be played, with the facts that decided it.
///
/// The request's `qn` is what was *asked for*; this is what came back. They
/// differ whenever the account cannot fetch 4K, when the server serves an SDR
/// rung for an HDR id, or when the codec preference loses to stability. The
/// player info panel reads this instead of the request id, which is how a 1080P
/// stream could be labelled "4K".
@immutable
class SelectedRendition {
  const SelectedRendition({
    required this.video,
    required this.format,
    required this.decode,
    required this.requestedQuality,
    this.fallback,
  });

  final VideoItem video;
  final FormatItem format;
  final VideoDecodeFormatType decode;

  /// The quality id that was requested.
  final int requestedQuality;

  /// Why this is not the requested rendition, when it is not.
  final RenditionFallback? fallback;

  int get width => video.width ?? 0;
  int get height => video.height ?? 0;
  String? get codecs => video.codecs;
  String? get frameRate => video.frameRate;

  /// True when the request was honoured exactly.
  bool get isExact => fallback == null;

  /// Short identity, used as the source key and for diagnostics.
  String sourceKey(String contentKey) =>
      '$contentKey:${video.id}:${video.codecs}';

  @override
  String toString() =>
      'SelectedRendition(id=${video.id} ${width}x$height '
      'codecs=${video.codecs} requested=$requestedQuality '
      'fallback=${fallback?.reason.name ?? 'none'})';
}

/// Why a fallback was chosen, and what it kept.
///
/// Resolution is preserved first: a 4K rendition that cannot be decoded is
/// replaced by another 4K rendition, and only a ladder with no playable 4K at
/// all drops a rung - and then says so.
enum RenditionFallbackReason {
  /// The requested id is not in the ladder.
  notServed,
  /// The codec preference is not offered; a same-resolution sibling was used.
  codecNotOffered,
  /// The preferred codec is present but the device cannot decode it.
  codecUnsupported,
  /// An HDR/Dolby Vision rung was available but the path cannot present it.
  hdrNotPresentable,
  /// A Dolby Vision rung was available but only a profile the renderer cannot
  /// reproduce. Profile 5 stores IPT-PQ-c2 samples with no HDR10/HLG base
  /// layer, so a renderer that ignores the RPU shifts every colour (the
  /// green/purple cast) - it is not a tone-mapping problem. Profiles 7 and 8
  /// keep a compatible base and are not covered by this reason.
  dolbyVisionUnsupportedProfile,
  /// Nothing at the requested resolution is playable.
  resolutionUnavailable,
}

@immutable
class RenditionFallback {
  const RenditionFallback({
    required this.reason,
    required this.fromQuality,
    required this.keptResolution,
    this.detail,
  });

  final RenditionFallbackReason reason;
  final int fromQuality;

  /// True when the substitute has the same pixel dimensions as the request.
  final bool keptResolution;

  /// What the user is told. One line, no jargon.
  final String? detail;

  String get message => detail ?? switch (reason) {
    RenditionFallbackReason.notServed => '该清晰度未提供，已选择最接近的一档',
    RenditionFallbackReason.codecNotOffered => '该编码未提供，已切换同分辨率编码',
    RenditionFallbackReason.codecUnsupported => '该编码不支持，已切换同分辨率编码',
    RenditionFallbackReason.hdrNotPresentable => '当前设备不支持 HDR，已切换同分辨率 SDR',
    RenditionFallbackReason.dolbyVisionUnsupportedProfile =>
      '该杜比视界片源为 Profile 5，当前渲染路径无法正确还原色彩，已切换同分辨率档位',
    RenditionFallbackReason.resolutionUnavailable => '该分辨率暂不可播放，已降低一档',
  };
}
