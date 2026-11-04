import Foundation

/// Whether the current output path can actually present extended range.
///
/// Two different questions were being answered with one flag, and the mistake
/// was measurable: a simulator running on an HDR-capable Mac reports
/// `eligibleForHDRPlayback == true` because the *device model* is capable, while
/// `availableHDRModes` is zero because no HDR output exists. Routing a PQ
/// rendition there decodes but the picture freezes.
///
/// Kept as pure logic so both branches can be asserted on the host, without a
/// device, a simulator or AVFoundation.
struct HdrCapability: Equatable {
  /// The device model could play HDR, per `AVPlayer.eligibleForHDRPlayback`.
  let eligible: Bool

  /// The iOS 17+ mode mask. Only meaningful when [modesKnown] is true.
  let modes: Int

  /// False on iOS 15/16, where the mask does not exist.
  let modesKnown: Bool

  init(eligible: Bool, modes: Int, modesKnown: Bool) {
    self.eligible = eligible
    self.modes = modes
    self.modesKnown = modesKnown
  }

  /// Whether the presenter should route a 10-bit/HDR rendition here.
  ///
  /// Where the mode mask exists it decides, because it describes the live
  /// output path. Where it does not, eligibility is the only answer available
  /// and is used as such - refusing outright would strand iOS 15/16 devices
  /// that can play HDR perfectly well.
  var canPresent: Bool { modesKnown ? modes != 0 : eligible }

  /// Why not, for the UI to state instead of leaving a black rectangle.
  var reason: String? {
    if canPresent { return nil }
    if modesKnown && modes == 0 { return "当前输出通路没有可用的 HDR 显示模式" }
    if !eligible { return "该设备不支持 HDR 播放" }
    return nil
  }
}
