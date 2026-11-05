import 'package:PiliPlus/models/common/video/base_quality.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/video/play/url.dart'
    show AudioItem, VideoItem, FormatItem;
import 'package:PiliPlus/models_new/live/live_room_play_info/codec.dart';
import 'package:PiliPlus/plugin/pl_player/models/av1_capability.dart';
import 'package:PiliPlus/plugin/pl_player/models/selected_rendition.dart';
import 'package:PiliPlus/plugin/pl_player/utils/av1_capability_probe.dart';
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

  /// Codecs this build can hand to a hardware decoder right now.
  ///
  /// AV1 VideoToolbox exists on the hardware but is not in the Flutter-bundled
  /// Avcodec: mpv reports `hwdec=no` and falls back to libdav1d, which decodes
  /// a 2160p AV1 stream on the CPU. Measured on device: 71 of 71 samples were
  /// `hwdec=no format=av1`, and that is the heat and the stutter.
  ///
  /// The patched Avcodec in `ios/av1` carries the backport, so AV1 is only
  /// demoted when that library was not injected. Demotion is a preference
  /// change, not a refusal: if the ladder offers nothing else, AV1 still plays.
  /// AV1 hardware decoding, layer by layer, for this build and this session.
  static Av1Capability get av1Capability => Av1CapabilityProbe.capability;

  /// Whether AV1 may be selected at all.
  ///
  /// Only an established "this build has no AV1 VideoToolbox decoder" demotes
  /// it. An unanswered probe keeps AV1 in the order: the decision costs one
  /// codec when it is wrong in that direction, and costs the whole codec when it
  /// is wrong in the other.
  static bool get av1HardwareAvailable =>
      av1LibraryState != CapabilityState.unsupported;

  /// The media-library layer alone, with the test override applied.
  static CapabilityState get av1LibraryState {
    final override = _av1LibraryOverride;
    if (override != null) {
      return override ? CapabilityState.supported : CapabilityState.unsupported;
    }
    return Av1CapabilityProbe.capability.mediaLibrary;
  }

  /// Test seam: pins the media-library layer without a platform channel.
  ///
  /// `null` restores the probed answer.
  static void setAv1HardwareAvailable(bool? value) => _av1LibraryOverride = value;

  static bool? _av1LibraryOverride;

  static VideoDecodeFormatType selectCodec(
    Iterable<String> codecs,
    List<VideoDecodeFormatType> preferCodecs,
  ) {
    // Without an AV1-capable decoder, preferring AV1 only buys a software
    // fallback. Drop it from the preference order so the next rung (HEVC) is
    // chosen instead; AV1 stays reachable through the unknown-codec path below
    // if it is the only thing offered.
    if (av1LibraryState == CapabilityState.unsupported &&
        preferCodecs.contains(VideoDecodeFormatType.AV1)) {
      final demoted = preferCodecs
          .where((e) => e != VideoDecodeFormatType.AV1)
          .toList();
      if (demoted.isNotEmpty) {
        return selectCodecIgnoringAv1(codecs, demoted);
      }
    }
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

  /// [selectCodec] with the AV1 entry already removed.
  ///
  /// Split out so the demotion cannot recurse: calling [selectCodec] again
  /// would re-enter the check and, if AV1 were re-added by a caller, loop.
  static VideoDecodeFormatType selectCodecIgnoringAv1(
    Iterable<String> codecs,
    List<VideoDecodeFormatType> preferCodecs,
  ) {
    int bestIndex = preferCodecs.length;
    for (final e in codecs) {
      for (int i = 0; i < bestIndex; i++) {
        if (preferCodecs[i].codes.any(e.startsWith)) {
          bestIndex = i;
          if (bestIndex == 0) return preferCodecs[0];
          break;
        }
      }
    }
    if (bestIndex < preferCodecs.length) return preferCodecs[bestIndex];
    // Nothing in the preference order was offered. Fall through to whatever the
    // ladder does carry, including AV1 - a software decode beats no picture.
    final first = codecs.firstOrNull;
    if (first != null) {
      for (final e in VideoDecodeFormatType.values) {
        if (e.codes.any(first.startsWith)) return e;
      }
    }
    return preferCodecs.first;
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

  /// Whether the player area should show the failure panel.
  ///
  /// A failed playurl leaves `videoState` false, so the area used to render
  /// nothing at all and the only explanation was a two-second toast. The panel
  /// needs something to say, so an empty message still means "render nothing".
  static bool showsPlayErrorPanel(String? message) =>
      message != null && message.trim().isNotEmpty;

  /// The message to show when the request itself throws, rather than returning
  /// a parsed Error.
  ///
  /// Kept here so the retry path's contract is assertable without spinning up a
  /// controller: whatever happens, a failure must leave a displayable message
  /// behind, otherwise the panel silently disappears.
  static const String playErrorOnException = '加载失败，请稍后重试';

  /// Message to store after a fetch settles.
  ///
  /// [threw] distinguishes "the request returned an Error" from "the request
  /// blew up"; only the latter needs the fallback text, because an Error already
  /// carries its own message.
  static String playErrorMessage({
    required String? parsedMessage,
    required bool threw,
  }) {
    if (threw) return playErrorOnException;
    final parsed = parsedMessage?.trim();
    return (parsed != null && parsed.isNotEmpty)
        ? parsed
        : playErrorOnException;
  }

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
    // Dolby Vision uses its own sample entry: `dvh1.05.09` is profile 05 /
    // level 09 and always ten-bit. Missing this classified a profile-5 stream
    // as 8-bit, which routed it to mpv - a path that cannot apply the RPU.
    if (codecs.startsWith('dvh1.') || codecs.startsWith('dvhe.')) {
      return true;
    }
    if (codecs.startsWith('av01.')) {
      // av01.P.LLT.DD... - the fourth dot-separated field is the bit depth.
      final parts = codecs.split('.');
      if (parts.length >= 4 && parts[3] == '10') return true;
    }
    return false;
  }

  /// The Dolby Vision profile in a sample-entry codec string, if any.
  ///
  /// `dvh1.05.09`: the field after the four-character code is the profile. It is
  /// available before playback, which is what lets the caller route a Dolby
  /// track to the native layer instead of guessing.
  static int? dolbyVisionProfileOf(String? codecs) {
    if (codecs == null || codecs.isEmpty) return null;
    if (!codecs.startsWith('dvh1.') && !codecs.startsWith('dvhe.')) {
      return null;
    }
    final parts = codecs.split('.');
    return parts.length < 2 ? null : int.tryParse(parts[1]);
  }

  /// Whether a specific stream can be rendered by the current output path.
  ///
  /// Unlike [isSupportedVideoQuality] this also rejects a 10-bit stream whose
  /// quality id is not in the known blocklist.
  static bool isSupportedVideoStream(int? quality, String? codecs) =>
      isSupportedVideoQuality(quality) &&
      (HdrSupport.allowsHdrQuality || !isTenBitCodec(codecs));

  /// Whether a row in the in-player quality sheet can be chosen.
  ///
  /// Two conditions: the server actually offered the rung for this video, and
  /// the render path can draw it. The second check is what hides HDR/Dolby
  /// Vision, whose 10-bit streams show up green through the 8-bit texture.
  static bool isQualitySelectable(int? quality, Set<int> available) =>
      quality != null &&
      available.contains(quality) &&
      isSupportedVideoQuality(quality);

  /// The trailing label for a quality row.
  ///
  /// Streams the render path cannot draw get [unsupportedLabel] instead of
  /// their own description, so the row reads as unavailable rather than broken.
  /// Formats the catalogue lists without a container string used to render an
  /// empty trailing label, which left a visibly blank slot; fall back to the id.
  static String qualityRowLabel(
    int? quality,
    String? format,
    String unsupportedLabel,
  ) {
    if (!isSupportedVideoQuality(quality)) return unsupportedLabel;
    final fmt = format?.trim();
    if (fmt != null && fmt.isNotEmpty) return fmt;
    return '#${quality ?? '?'}';
  }

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

  /// The single place a rendition is chosen, and it says what it chose.
  ///
  /// Stability first: the requested resolution is kept whenever *any* codec at
  /// that resolution is playable, and the requested codec is only re-chosen
  /// when it is not offered or not decodable. The returned record carries the
  /// alternative's reason so the UI can explain a downgrade instead of silently
  /// showing 1080P under a 4K request.
  static SelectedRendition selectRendition({
    required List<VideoItem> videoList,
    required List<FormatItem> supportFormats,
    required List<VideoDecodeFormatType> preferCodecs,
    required int preferQuality,
    List<int>? acceptQuality,
    required bool allowTenBit,
    required bool allowHdrRungs,
  }) {
    final available = <int>{for (final e in videoList) e.id};

    // An HDR rung is kept only when the path can present it. This is decided on
    // the *requested* id first: _findAvailableVideoQuality has already folded
    // an HDR request down to an SDR one by the time it returns, which would
    // erase the evidence that a downgrade happened at all.
    RenditionFallback? fallback;
    var requested = preferQuality;
    if (!allowHdrRungs && hdrVideoQualities.contains(requested)) {
      final sdr = _highestSupported(available.difference(hdrVideoQualities));
      if (sdr != null) {
        fallback = RenditionFallback(
          reason: RenditionFallbackReason.hdrNotPresentable,
          fromQuality: requested,
          keptResolution:
              _heightOf(videoList, sdr) == _heightOf(videoList, requested),
        );
        requested = sdr;
      }
    }

    var targetQuality = _findAvailableVideoQuality(
      videoList,
      acceptQuality,
      requested,
    );

    // Still an HDR id (the ladder only offers HDR): fall to any SDR rung rather
    // than opening a 10-bit PQ track on an 8-bit surface.
    if (!allowHdrRungs && hdrVideoQualities.contains(targetQuality)) {
      final sdr = _highestSupported(
        available.difference(hdrVideoQualities),
      );
      if (sdr != null) {
        fallback = RenditionFallback(
          reason: RenditionFallbackReason.hdrNotPresentable,
          fromQuality: targetQuality,
          keptResolution:
              _heightOf(videoList, sdr) == _heightOf(videoList, targetQuality),
        );
        targetQuality = sdr;
      }
    }

    final targetFormat = supportFormats.firstWhere(
      (e) => e.quality == targetQuality,
      orElse: () => supportFormats.first,
    );
    final targetDecode = selectCodec(targetFormat.codecs!, preferCodecs);

    final variants = videoList.where((e) => e.id == targetQuality).toList();
    final targetVideo = selectVideoVariant(
      variants,
      targetDecode,
      allowTenBit: allowTenBit,
    );

    fallback ??= _explainVariant(
      requestedQuality: preferQuality,
      chosenQuality: targetVideo.id,
      variants: variants,
      chosen: targetVideo,
      requestedDecode: targetDecode,
    );

    if (kDebugMode) {
      debugPrint('QA_PICK prefer=$preferQuality picked=${targetVideo.id} '
          'codec=${targetVideo.codecs} available=$available');
    }

    return SelectedRendition(
      video: targetVideo,
      format: targetFormat,
      decode: targetDecode,
      requestedQuality: preferQuality,
      fallback: fallback,
    );
  }

  static int? _heightOf(List<VideoItem> list, int quality) {
    for (final e in list) {
      if (e.id == quality) return e.height;
    }
    return null;
  }

  /// Why the chosen variant is not the one the preference asked for.
  ///
  /// Only reported when the *codec* changed. A different quality id is already
  /// explained by [_findAvailableVideoQuality] and by the HDR gate above.
  static RenditionFallback? _explainVariant({
    required int requestedQuality,
    required int chosenQuality,
    required List<VideoItem> variants,
    required VideoItem chosen,
    required VideoDecodeFormatType requestedDecode,
  }) {
    if (variants.isEmpty) return null;
    final wanted = variants.any(
      (e) => requestedDecode.codes.any((c) => (e.codecs ?? '').startsWith(c)),
    );
    final gotWanted = requestedDecode.codes.any(
      (c) => (chosen.codecs ?? '').startsWith(c),
    );
    if (gotWanted) return null;
    if (!wanted && variants.length == 1) return null;
    return RenditionFallback(
      reason: wanted
          ? RenditionFallbackReason.codecUnsupported
          : RenditionFallbackReason.codecNotOffered,
      fromQuality: requestedQuality,
      keptResolution: chosenQuality == chosen.id,
      detail: wanted
          ? '首选编码不可用，已切换同分辨率编码'
          : '该编码未提供，已切换同分辨率编码',
    );
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
