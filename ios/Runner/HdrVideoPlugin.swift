import AVFoundation
import Flutter
import UIKit

/// Hosts an `AVPlayerLayer` inside the Flutter widget tree.
///
/// mpv renders through a Flutter texture, and every texture buffer on iOS is
/// 8-bit BGRA - an external texture cannot carry extended range. `AVPlayerLayer`
/// is the only public surface that composites HDR, so HDR playback is delegated
/// to it while mpv keeps handling SDR, danmaku and subtitles.
final class HdrVideoPlugin: NSObject, FlutterPlugin {
  /// Live controllers, keyed by the platform view id so Dart can drive them.
  static var controllers: [Int64: HdrVideoController] = [:]

  static func register(with registrar: FlutterPluginRegistrar) {
    registrar.register(
      HdrVideoViewFactory(messenger: registrar.messenger()),
      withId: "pilipilus/hdr_video"
    )

    let channel = FlutterMethodChannel(
      name: "pilipilus/hdr_video/control",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(HdrVideoPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let id = Int64(args["id"] as? Int ?? -1)

    if call.method == "dispose" {
      HdrVideoPlugin.controllers.removeValue(forKey: id)?.dispose()
      result(nil)
      return
    }

    guard let controller = HdrVideoPlugin.controllers[id] else {
      result(FlutterError(code: "no_controller",
                          message: "no controller for id \(id)",
                          details: nil))
      return
    }

    switch call.method {
    case "play":
      controller.play()
      result(nil)
    case "pause":
      controller.pause()
      result(nil)
    case "seek":
      controller.seek(toMs: args["ms"] as? Int ?? 0)
      result(nil)
    case "describe":
      result(controller.describe())
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

final class HdrVideoController {
  let player: AVPlayer
  let layer: AVPlayerLayer
  private(set) var edrRequested = false

  init(url: URL) {
    player = AVPlayer(playerItem: AVPlayerItem(url: url))
    layer = AVPlayerLayer(player: player)
    layer.videoGravity = .resizeAspect
    if #available(iOS 17.0, *) {
      // The whole point of using AVPlayerLayer instead of a texture.
      layer.wantsExtendedDynamicRangeContent = true
      edrRequested = true
    }
  }

  func play() { player.play() }
  func pause() { player.pause() }
  func seek(toMs ms: Int) {
    player.seek(to: CMTime(value: CMTimeValue(ms), timescale: 1000))
  }
  func dispose() {
    player.pause()
    layer.removeFromSuperlayer()
  }

  /// What the platform is actually presenting, so the UI can say whether the
  /// picture is HDR rather than assuming it.
  func describe() -> [String: Any] {
    var out: [String: Any] = ["edrRequested": edrRequested]
    guard let item = player.currentItem else { return out }

    let size = item.presentationSize
    out["width"] = Int(size.width)
    out["height"] = Int(size.height)

    guard
      let track = item.tracks.first(where: { $0.assetTrack?.mediaType == .video }),
      let assetTrack = track.assetTrack,
      let description = assetTrack.formatDescriptions.first
    else { return out }

    let format = description as! CMFormatDescription
    if let ext = CMFormatDescriptionGetExtensions(format) as? [String: Any] {
      let primaries = ext["ColorPrimaries"] as? String
      let transfer = ext["TransferFunction"] as? String
      out["primaries"] = primaries
      out["transfer"] = transfer
      // PQ (HDR10) and HLG are the two extended-range transfer functions the
      // catalogue serves; anything else is SDR.
      out["hdr"] = (transfer?.contains("2084") == true) ||
        (transfer?.contains("HLG") == true)
    }
    return out
  }
}

final class HdrVideoViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    HdrVideoPlatformView(
      frame: frame,
      viewId: viewId,
      args: args as? [String: Any] ?? [:]
    )
  }
}

final class HdrVideoPlatformView: NSObject, FlutterPlatformView {
  private let container = UIView()

  init(frame: CGRect, viewId: Int64, args: [String: Any]) {
    super.init()

    container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    container.backgroundColor = .black
    container.frame = frame

    guard
      let raw = args["url"] as? String,
      let url = URL(string: raw)
    else { return }

    let controller = HdrVideoController(url: url)
    HdrVideoPlugin.controllers[viewId] = controller

    controller.layer.frame = container.bounds
    container.layer.addSublayer(controller.layer)
  }

  func view() -> UIView { container }
}
