import 'package:PiliPlus/models/common/video/base_quality.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/video/play/url.dart'
    show AudioItem, VideoItem, FormatItem;
import 'package:PiliPlus/models_new/live/live_room_play_info/codec.dart';
import 'package:PiliPlus/plugin/pl_player/utils/hdr_support.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

abstract final class VideoUtils {
  static CDNService cdnService = Pref.defaultCDNService;
  static String? liveCdnUrl = Pref.liveCdnUrl;
  static bool disableAudioCDN = Pref.disableAudioCDN;

  static const _proxyTf = 'proxy-tf-all-ws.bilivideo.com';

  static final _mirrorRegex = RegExp(
    r'^https?://(?:upos-\w+-(?!302)\w+|(?:upos|proxy)-tf-[^/]+)\.(?:bilivideo|akamaized)\.(?:com|net)/upgcxcode',
  );

  static final _mCdnTfRegex = RegExp(
    r'^https?://(?:(?:(?:\d{1,3}\.){3}\d{1,3}|[^/]+\.mcdn\.bilivideo\.(?:com|cn|net))(?:\:\d{1,5})?/v\d/resource)',
  );

  static String getCdnUrl(
    Iterable<String> urls, {
    CDNService? defaultCDNService,
    bool isAudio = false,
  }) {
    defaultCDNService ??= cdnService;

    if (defaultCDNService == CDNService.baseUrl) {
      return urls.first;
    }

    if (defaultCDNService == CDNService.akamai &&
        !(isAudio && disableAudioCDN)) {
      // Akamai URLs have their own signature (e.g. hdnts). Replacing another
      // CDN's host preserves the wrong signature and results in HTTP 403.
      // Keep the API-provided URL intact, including its encoded query string.
      return urls.firstWhere(
        (url) => Uri.tryParse(url)?.host == CDNService.akamai.host,
        orElse: () => urls.first,
      );
    }

    String? mcdnTf;
    String? mcdnUpgcxcode;

    String last = '';
    for (final url in urls) {
      last = url;
      if (_mirrorRegex.hasMatch(url)) {
        final uri = Uri.parse(url);
        if (uri.queryParameters['os'] == 'mcdn') {
          // upos-sz-mirrorcoso1.bilivideo.com os=mcdn
          mcdnUpgcxcode = url;
        } else {
          if (defaultCDNService == CDNService.backupUrl ||
              (isAudio && disableAudioCDN)) {
            return url;
          }
          return uri.replace(host: defaultCDNService.host).toString();
        }
      }

      if (_mCdnTfRegex.hasMatch(url)) {
        mcdnTf = url;
        continue;
      }

      // upos-\w*-302.* & bcache & mcdn host but upgcxcode path
      if (url.contains('/upgcxcode/')) {
        mcdnUpgcxcode = url;
        continue;
      }

      // may be deprecated
      if (url.contains('szbdyd.com')) {
        final uri = Uri.parse(url);
        final hostname =
            uri.queryParameters['xy_usource'] ?? defaultCDNService.host;
        return uri
            .replace(scheme: 'https', host: hostname, port: 443)
            .toString();
      }

      if (kDebugMode) {
        debugPrint('unknown cdn type: $url');
      }
    }

    return mcdnUpgcxcode == null
        ? mcdnTf == null
              ? last
              : Uri(
                  scheme: 'https',
                  host: _proxyTf,
                  queryParameters: {'url': mcdnTf},
                ).toString()
        : Uri.parse(mcdnUpgcxcode)
              .replace(host: defaultCDNService.host ?? CDNService.ali.host)
              .toString();
  }

  static String getLiveCdnUrl(CodecItem e, {int index = 0}) {
    final urlInfo = e.urlInfo.getOrFirst(index);
    return (liveCdnUrl ?? urlInfo.host) + e.baseUrl + urlInfo.extra;
  }

  static VideoDecodeFormatType selectCodec(
    Iterable<String> codecs,
    List<VideoDecodeFormatType> preferCodecs,
  ) {
    if (preferCodecs.isNotEmpty) {
      int bestIndex = preferCodecs.length;
      for (final e in codecs) {
        for (int i = 0; i < bestIndex; i++) {
          if (preferCodecs[i].codes.any(e.startsWith)) {
            bestIndex = i;
            if (bestIndex == 0) {
              return preferCodecs[0];
            }
            break;
          }
        }
      }
      if (bestIndex < preferCodecs.length) {
        return preferCodecs[bestIndex];
      }
    }
    // A stream with a codec we do not know (e.g. vp09) must not abort the
    // lookup: keep the caller's first preference and let it fall back to the
    // first offered rendition.
    final first = codecs.firstOrNull;
    if (first != null) {
      for (final e in VideoDecodeFormatType.values) {
        if (e.codes.any(first.startsWith)) return e;
      }
    }
    return preferCodecs.firstOrNull ?? VideoDecodeFormatType.AVC;
  }

  /// Qualities this build must not select.
  ///
  /// HDR Vivid / Dolby Vision / HDR 真彩 are 10-bit HLG or PQ streams. The
  /// VideoToolbox path decodes them to `p010`, but the media_kit Darwin
  /// software/hardware textures are 8-bit BGRA, so rendering them produces a
  /// green image. Until the render path handles 10-bit, request and select the
  /// SDR ladder only.
  static const hdrVideoQualities = <int>{
    129, // HDR Vivid
    126, // 杜比视界
    125, // HDR 真彩
  };

  /// Qualities this build must not select on the current render path.
  static Set<int> get unsupportedVideoQualities =>
      HdrSupport.allowsHdrQuality ? const <int>{} : hdrVideoQualities;

  static bool isSupportedVideoQuality(int? quality) =>
      quality == null || !unsupportedVideoQualities.contains(quality);

  /// Whether a codec string describes a 10-bit stream.
  ///
  /// The id list above only covers the rungs Bilibili ships today. Checking the
  /// codec profile catches a new 10-bit rung whose id is not in the list yet:
  ///
  /// - HEVC: hvc1.2.4 / hev1.2.4 are Main10, hvc1.1.6 is Main (8-bit)
  /// - AV1:  `av01.<profile>.<level>M.<bitdepth>`, so `.10.` is 10-bit
  /// - AVC:  always 8-bit
  ///
  /// Observed live: 125 -> hvc1.2.4.L153.90, 122/120 -> hvc1.1.6.L153.90.
  static bool isTenBitCodec(String? codecs) {
    if (codecs == null || codecs.isEmpty) return false;
    if (codecs.startsWith('hev1.2') || codecs.startsWith('hvc1.2')) {
      return true;
    }
    if (codecs.startsWith('av01.')) {
      // av01.P.LLT.DD... - the fourth dot-separated field is the bit depth.
      final parts = codecs.split('.');
      if (parts.length >= 4 && parts[3] == '10') return true;
    }
    return false;
  }

  /// Whether a specific stream can be rendered by the current output path.
  ///
  /// Unlike [isSupportedVideoQuality] this also rejects a 10-bit stream whose
  /// quality id is not in the known blocklist.
  static bool isSupportedVideoStream(int? quality, String? codecs) =>
      isSupportedVideoQuality(quality) &&
      (HdrSupport.allowsHdrQuality || !isTenBitCodec(codecs));

  /// Picks the entry to play from the variants of one quality id.
  ///
  /// Prefers the entry matching the requested codec, then any renderable
  /// entry, and only falls back to the first one when nothing is renderable -
  /// so an unknown 10-bit variant cannot be chosen just because it came first.
  static VideoItem selectVideoVariant(
    List<VideoItem> variants,
    VideoDecodeFormatType decode, {
    required bool allowTenBit,
  }) {
    assert(variants.isNotEmpty);
    bool usable(VideoItem e) => allowTenBit || !isTenBitCodec(e.codecs);

    for (final e in variants) {
      if (usable(e) && decode.codes.any(e.codecs!.startsWith)) return e;
    }
    for (final e in variants) {
      if (usable(e)) return e;
    }
    return variants.first;
  }

  static int _findAvailableVideoQuality(
    List<VideoItem> videoList,
    List<int>? acceptQuality,
    int preferQuality,
  ) {
    // Never jump to a stream we cannot render. `videoList.first` is the highest
    // returned id, which is HDR whenever the account may fetch it.
    final available = <int>{for (final e in videoList) e.id};
    if (unsupportedVideoQualities.contains(preferQuality)) {
      preferQuality = _highestSupported(available) ?? preferQuality;
    }

    if (available.contains(preferQuality)) {
      return preferQuality;
    }

    final highest = videoList.first.id;
    if (preferQuality >= highest) {
      return _highestSupported(available) ?? highest;
    }

    if (acceptQuality != null && acceptQuality.isNotEmpty) {
      final supported = acceptQuality.where(isSupportedVideoQuality).toList();
      if (supported.isNotEmpty) {
        return supported.findTargetMedia((e) => e, preferQuality);
      }
    }

    final sdr = videoList.where((e) => isSupportedVideoQuality(e.id)).toList();
    final pool = sdr.isEmpty ? videoList : sdr;
    return pool.findTargetMedia((e) => e.id, preferQuality).quality.code;
  }

  static int? _highestSupported(Set<int> available) {
    int? best;
    for (final q in available) {
      if (!isSupportedVideoQuality(q)) continue;
      if (best == null || q > best) best = q;
    }
    return best;
  }

  static (
    int targetQuality,
    FormatItem targetFormat,
    VideoDecodeFormatType targetDecode,
    VideoItem targetVideo,
  )
  findTargetVideo(
    List<VideoItem> videoList,
    int preferQuality,
    List<int>? acceptQuality,
    List<FormatItem> supportFormats,
    List<VideoDecodeFormatType> preferCodecs,
  ) {
    assert(videoList.isNotEmpty);

    final targetQuality = _findAvailableVideoQuality(
      videoList,
      acceptQuality,
      preferQuality,
    );

    final targetFormat = supportFormats.firstWhere(
      (e) => e.quality == targetQuality,
      orElse: () => supportFormats.first,
    );

    final targetDecode = VideoUtils.selectCodec(
      targetFormat.codecs!,
      preferCodecs,
    );

    final targetQaVideoList = videoList
        .where((e) => e.id == targetQuality)
        .toList();

    final targetVideo = selectVideoVariant(
      targetQaVideoList,
      targetDecode,
      allowTenBit: HdrSupport.allowsHdrQuality,
    );

    // Diagnostic only in debug builds: makes it possible to confirm from the
    // simulator log which rendition was actually chosen, instead of inferring
    // it from the picture.
    if (kDebugMode) {
      debugPrint(
        'QA_PICK prefer=$preferQuality picked=${targetVideo.id} '
        'codec=${targetDecode.name} available=${videoList.map((e) => e.id).toList()}',
      );
    }

    return (targetVideo.id, targetFormat, targetDecode, targetVideo);
  }

  static AudioItem findTargetAudio(
    List<AudioItem> audioList,
    int preferQuality,
  ) {
    assert(audioList.isNotEmpty);

    final preferredRank = AudioQuality.fromCode(preferQuality).rank;
    return audioList.findTargetMedia(
      (audio) => AudioQuality.fromCode(audio.id).rank,
      preferredRank,
    );
  }
}
