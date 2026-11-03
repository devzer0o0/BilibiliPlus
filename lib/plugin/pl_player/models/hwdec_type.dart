// mpv --hwdec=help
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kDebugMode;

enum HwDecType {
  no('no', '启用软解'),
  auto('auto', '启用任意可用解码器'),
  autoSafe('auto-safe', '启用最佳解码器'),
  autoCopy('auto-copy', '启用带拷贝功能的最佳解码器'),
  d3d12va('d3d12va', 'DirectX 12 (Windows10 及以上)'),
  d3d12vaCopy('d3d12va-copy', 'DirectX 12 (Windows10 及以上) (非直通)'),
  d3d11va('d3d11va', 'DirectX 11 (Windows8 及以上)'),
  d3d11vaCopy('d3d11va-copy', 'DirectX 11 (Windows8 及以上) (非直通)'),
  dxva2('dxva2', 'DXVA2 (Windows7 及以上)'),
  dxva2Copy('dxva2-copy', 'DXVA2 (Windows7 及以上) (非直通)'),
  videotoolbox('videotoolbox', 'VideoToolbox (macOS / iOS)'),
  videotoolboxCopy('videotoolbox-copy', 'VideoToolbox (macOS / iOS) (非直通)'),
  vaapi('vaapi', 'VAAPI (Linux)'),
  vaapiCopy('vaapi-copy', 'VAAPI (Linux) (非直通)'),
  nvdec('nvdec', 'NVDEC (NVIDIA独占)'),
  nvdecCopy('nvdec-copy', 'NVDEC (NVIDIA独占) (非直通)'),
  drm('drm', 'DRM (Linux)'),
  drmCopy('drm-copy', 'DRM (Linux) (非直通)'),
  vulkan('vulkan', 'Vulkan (全平台) (实验性)'),
  vulkanCopy('vulkan-copy', 'Vulkan (全平台) (实验性) (非直通)'),
  vdpau('vdpau', 'VDPAU (Linux)'),
  vdpauCopy('vdpau-copy', 'VDPAU (Linux) (非直通)'),
  mediacodec('mediacodec', 'MediaCodec (Android)'),
  mediacodecCopy('mediacodec-copy', 'MediaCodec (Android) (非直通)'),
  cuda('cuda', 'CUDA (NVIDIA独占) (过时)'),
  cudaCopy('cuda-copy', 'CUDA (NVIDIA独占) (过时) (非直通)'),
  crystalhd('crystalhd', 'CrystalHD (全平台) (过时)'),
  rkmpp('rkmpp', 'Rockchip MPP (仅部分Rockchip芯片)'),
  amf('amf', 'AMF (AMD独占)'),
  amfCopy('amf-copy', 'AMF (AMD独占) (非直通)'),
  qsv('qsv', 'Quick Sync Video (Intel独占)'),
  qsvCopy('qsv-copy', 'Quick Sync Video (Intel独占) (非直通)'),
  ;

  final String hwdec;
  final String desc;
  const HwDecType(this.hwdec, this.desc);

  static final String kHwdec = Platform.isAndroid
      ? kDebugMode
            ? autoSafe.hwdec
            : [mediacodec.hwdec, autoSafe.hwdec].join(',')
      : auto.hwdec;

  /// Values that mean anything on the current platform.
  ///
  /// The dialog used to list every mpv backend, so an iPhone user had to scroll
  /// past DirectX, VAAPI, VDPAU, CUDA, QSV and Rockchip entries to reach
  /// `videotoolbox`. Keep the generic entries plus the backends that exist on
  /// this OS.
  static List<HwDecType> get valuesForPlatform =>
      valuesFor(Platform.operatingSystem);

  /// The same filter, for a named platform. Exists so the rules can be tested
  /// for iOS from a machine that is not an iPhone.
  static List<HwDecType> valuesFor(String operatingSystem) {
    const generic = <HwDecType>{no, auto, autoSafe, autoCopy};
    final platformSpecific = switch (operatingSystem) {
      // iPhone Air never takes the copy-back path: VideoToolbox hands mpv
      // CVPixelBuffers directly, so every device log shows hwdec=videotoolbox
      // and never videotoolbox-copy. Offering it only invites a slower mode with
      // no benefit. macOS keeps it - it is a different machine.
      //
      // The animated-screenshot transcoder appends its own ",auto-copy"
      // (see mpv_convert_webp.dart), so it does not depend on this entry.
      'ios' => <HwDecType>{videotoolbox},
      'macos' => <HwDecType>{videotoolbox, videotoolboxCopy},
      'android' => <HwDecType>{mediacodec, mediacodecCopy},
      'windows' => <HwDecType>{
        d3d12va,
        d3d12vaCopy,
        d3d11va,
        d3d11vaCopy,
        dxva2,
        dxva2Copy,
        vulkan,
        vulkanCopy,
        cuda,
        cudaCopy,
        qsv,
        qsvCopy,
        amf,
        amfCopy,
      },
      'linux' => <HwDecType>{
        vaapi,
        vaapiCopy,
        drm,
        drmCopy,
        vdpau,
        vdpauCopy,
        vulkan,
        vulkanCopy,
        cuda,
        cudaCopy,
        rkmpp,
      },
      _ => <HwDecType>{vulkan, vulkanCopy},
    };
    return values.where((e) => generic.contains(e) || platformSpecific.contains(e)).toList();
  }
}
