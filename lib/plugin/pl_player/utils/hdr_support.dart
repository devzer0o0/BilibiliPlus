import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/services.dart' show MethodChannel;

import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

/// Whether the current build can render HDR (10-bit) video correctly.
///
/// The Bilibili HDR ladder (129/126/125) is HEVC Main10 HLG or Dolby Vision.
/// VideoToolbox decodes those to `p010`, but media_kit's Darwin video output
/// copies frames into a fixed 8-bit BGRA `CVPixelBuffer`
/// (`kCVPixelFormatType_32BGRA` in both `TextureSWContext` and
/// `OpenGLESHelpers.createPixelBuffer`). Feeding 10-bit planes into an 8-bit
/// texture without a tone-mapping pass shows up as a green image.
///
/// [toneMappedPlayerOptions] lets libplacebo convert HDR into the SDR gamut
/// first, which is correct but costs a full-range conversion per frame. Until
/// the texture path is 10-bit end to end, HDR stays opt-in behind this switch.
/// What the native path said about HDR, with the reasons kept separate.
///
/// [eligible] is the device's own answer (eligibleForHDRPlayback);
/// [canPresent] is whether the current output can actually show it. Neither is
/// evidence that a picture is being displayed with extended range.
@immutable
class HdrPathCapability {
  const HdrPathCapability({
    required this.canPresent,
    required this.eligible,
    this.availableModes = 0,
    this.reason,
  });

  final bool canPresent;
  final bool eligible;
  final int availableModes;
  final String? reason;

  @override
  String toString() =>
      'HdrPathCapability(canPresent=$canPresent eligible=$eligible '
      'modes=$availableModes reason=${reason ?? '-'})';
}

abstract final class HdrSupport {
  /// Set to true once the Darwin texture path carries 10-bit frames.
  ///
  /// Still false: the Flutter texture is 8-bit and cannot. HDR is instead
  /// handed to AVPlayerLayer (see [nativeHdrPath]), which is a different
  /// renderer rather than a wider texture.
  static const bool nativeTenBitPath = false;

  /// iOS 17 added `AVPlayerLayer.wantsExtendedDynamicRangeContent`, which is
  /// the only public way to composite extended-range video. Where it exists the
  /// HDR ladder plays for real, through the native layer, instead of being
  /// tone-mapped down to SDR.
  static bool get nativeHdrPath => Platform.isIOS;

  /// User switch: allow HDR qualities with the tone-mapped SDR fallback.
  ///
  /// Defaults to off; the setting lives in 设置 -> 播放设置.
  static bool get enableToneMappedHdr => Pref.enableToneMappedHdr;

  static bool get isIOS => Platform.isIOS;

  /// HDR experiences that only work on the true 10-bit path.
  static bool get supportsNativeHdr => isIOS && nativeTenBitPath;

  /// HDR experiences that render acceptably through tone mapping.
  static bool get supportsToneMappedHdr =>
      isIOS && (nativeTenBitPath || enableToneMappedHdr);

  /// True when the quality ladder may offer 125/126/129 at all.
  static bool get allowsHdrQuality =>
      nativeHdrPath || supportsNativeHdr || supportsToneMappedHdr;

  /// Whether this particular device can present extended range right now.
  ///
  /// [nativeHdrPath] only says the build has a native surface. A simulator, or
  /// a device with HDR off, reports no HDR display mode: sending a PQ rendition
  /// there makes AVFoundation filter out every alternate, so the item never
  /// becomes ready and the screen stays black. Routing must use this, not the
  /// platform check alone.
  static Future<bool> canPresentHdr() async =>
      (await describeHdrPath())?.canPresent ?? false;

  /// The capability answer, with the reasons behind it.
  ///
  /// Cached for a short while rather than forever: HDR availability changes
  /// when an external display is attached, when display settings change and
  /// when the system reports a new mode list. A cached "no" for the whole
  /// session is what made a capable device look incapable after one early call.
  static HdrPathCapability? _cached;
  static DateTime? _cachedAt;
  static const _cacheWindow = Duration(seconds: 20);

  static Future<HdrPathCapability?> describeHdrPath() async {
    if (!nativeHdrPath) {
      return const HdrPathCapability(
        canPresent: false,
        eligible: false,
        reason: '当前渲染通路为 8-bit 纹理',
      );
    }
    final at = _cachedAt;
    if (at != null && DateTime.now().difference(at) < _cacheWindow) {
      return _cached;
    }
    try {
      final result = await const MethodChannel(
        'pilipilus/hdr_video/control',
      ).invokeMethod<Map>('hdrCapability');
      final eligible = result?['eligibleForHdrPlayback'] == true;
      final modes = (result?['availableHdrModes'] as num?)?.toInt() ?? 0;
      final canPresent = result?['supported'] == true;
      final capability = HdrPathCapability(
        canPresent: canPresent,
        eligible: eligible,
        availableModes: modes,
        reason: canPresent
            ? null
            : '设备或当前输出不支持 HDR 呈现',
      );
      _cached = capability;
      _cachedAt = DateTime.now();
      return capability;
    } catch (_) {
      // No native side means no native HDR surface.
      return const HdrPathCapability(
        canPresent: false,
        eligible: false,
        reason: '原生播放组件不可用',
      );
    }
  }

  /// Drops the cached answer. Called when the app returns to the foreground or
  /// a display configuration change is reported.
  static void invalidateCapabilityCache() {
    _cached = null;
    _cachedAt = null;
  }

  /// mpv options required to render HDR through an 8-bit output.
  static Map<String, String> get toneMappedPlayerOptions => {
    'tone-mapping': 'auto',
    'hdr-compute-peak': 'yes',
    'target-colorspace-hint': 'yes',
  };

  /// Describes why a platform cannot show HDR, for the settings UI.
  static String? get unsupportedReason {
    if (!PlatformUtils.isMobile) return null;
    if (allowsHdrQuality) return null;
    return '当前渲染通路为 8-bit，HDR/杜比视界会花屏，已暂时隐藏';
  }
}
