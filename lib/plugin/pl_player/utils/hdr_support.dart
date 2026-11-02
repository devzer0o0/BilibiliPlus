import 'dart:io' show Platform;

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
abstract final class HdrSupport {
  /// Set to true once the Darwin texture path carries 10-bit frames.
  static const bool nativeTenBitPath = false;

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
      supportsNativeHdr || supportsToneMappedHdr;

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
