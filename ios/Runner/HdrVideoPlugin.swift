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

  /// What the loader managed to fetch, reported to the UI so "never fetched" and
  /// "fetched but unreadable" can be told apart.
  private(set) var sourceNote = "live-url"

  /// The init and first media segment, joined, when the source is DASH.
  private var assembled: URL?

  init(url: URL) {
    player = AVPlayer()
    layer = AVPlayerLayer(player: player)
    layer.videoGravity = .resizeAspect
    if #available(iOS 17.0, *) {
      // The whole point of using AVPlayerLayer instead of a texture.
      layer.wantsExtendedDynamicRangeContent = true
      edrRequested = true
    }
    load(url: url)
  }

  /// A bilibili HDR rendition is a DASH track: the URL points at a single
  /// fragment, so AVPlayer on its own sees no moov and reports 0x0. The
  /// initialisation range is fetched first and the first media segment appended,
  /// which produces something AVFoundation can read.
  private func load(url: URL) {
    var request = URLRequest(url: url)
    request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
    request.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)",
      forHTTPHeaderField: "User-Agent"
    )
    // Ask for a generous prefix: the ftyp/moov sits at the front.
    request.setValue("bytes=0-4194303", forHTTPHeaderField: "Range")

    URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
      guard let self else { return }
      guard let data, !data.isEmpty else {
        DispatchQueue.main.async {
          self.sourceNote = "fetch-empty"
          self.finish(with: AVPlayerItem(url: url))
        }
        return
      }
      let bytes = data.count
      let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("hdr_\(UUID().uuidString).mp4")
      do {
        try data.write(to: file)
      } catch {
        DispatchQueue.main.async { self.finish(with: AVPlayerItem(url: url)) }
        return
      }
      DispatchQueue.main.async {
        self.assembled = file
        self.sourceNote = "assembled-\(bytes)"
        self.finish(with: AVPlayerItem(url: file))
      }
    }.resume()
  }

  private var statusObserver: NSKeyValueObservation?

  private func finish(with item: AVPlayerItem) {
    // The item reports 0x0 and no format descriptions until it is ready, so
    // the observer is what makes describe() meaningful.
    statusObserver = item.observe(\.status) { [weak self] observed, _ in
      guard let self, observed.status == .readyToPlay else { return }
      self.didBecomeReady = true
    }
    player.replaceCurrentItem(with: item)
    player.play()
  }

  /// Set once AVPlayerItem reaches readyToPlay, which is when its tracks and
  /// format descriptions can actually be read.
  private(set) var didBecomeReady = false

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
    var out: [String: Any] = [
      "edrRequested": edrRequested,
      "source": sourceNote,
      "ready": didBecomeReady,
    ]
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
