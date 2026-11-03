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
    sweepStaleFiles()
  }

  /// Removes tracks left by an earlier run.
  ///
  /// dispose() only runs when the widget is torn down in order. A force-quit or
  /// a termination by the system skips it, and each such run leaves a hundred
  /// megabytes behind - two of them already filled the container. Sweeping at
  /// start makes the leak self-healing instead of cumulative.
  private static func sweepStaleFiles() {
    let tmp = FileManager.default.temporaryDirectory
    guard let names = try? FileManager.default.contentsOfDirectory(
      at: tmp, includingPropertiesForKeys: nil
    ) else { return }
    for url in names {
      let n = url.lastPathComponent
      guard n.hasPrefix("hdr_") || n.hasPrefix("audio_") else { continue }
      try? FileManager.default.removeItem(at: url)
    }
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

  /// The separate audio track bilibili serves for DASH.
  private var audioUrl: URL?

  /// The assembled audio file, removed on dispose like the video one.
  private var audioFile: URL?

  init(url: URL, audioUrl: URL? = nil) {
    player = AVPlayer()
    layer = AVPlayerLayer(player: player)
    layer.videoGravity = .resizeAspect
    if #available(iOS 17.0, *) {
      // The whole point of using AVPlayerLayer instead of a texture.
      layer.wantsExtendedDynamicRangeContent = true
      edrRequested = true
    }
    self.audioUrl = audioUrl
    load(url: url)
  }

  /// A bilibili HDR rendition is a DASH track: a moov followed by one moof+mdat
  /// per fragment. AVPlayer cannot be pointed at the URL directly, so the track
  /// is fetched fragment by fragment (see DashAssembler) and written to a file.
  private func load(url: URL) {
    let headers = [
      "Referer": "https://www.bilibili.com",
      "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)",
    ]

    DashAssembler.assemble(url: url, headers: headers) { [weak self] result in
      guard let self else { return }
      guard let result, !result.data.isEmpty else {
        DispatchQueue.main.async {
          self.sourceNote = "assemble-failed"
          self.finish(with: AVPlayerItem(url: url))
        }
        return
      }

      let bytes = result.data.count
      let fragments = result.fragments
      let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("hdr_\(UUID().uuidString).mp4")
      // bilibili serves HDR as 'hev1', which AVFoundation refuses to play even
      // though the bitstream is identical to 'hvc1'. The parameter sets already
      // live in hvcC, so rewriting the fourcc is enough.
      let patched = HdrVideoController.asHvc1(result.data)
      guard (try? patched.write(to: file)) != nil else {
        DispatchQueue.main.async {
          self.sourceNote = "write-failed"
          self.finish(with: AVPlayerItem(url: url))
        }
        return
      }
      DispatchQueue.main.async {
        self.assembled = file
        self.sourceNote = "fragments=\(fragments) bytes=\(bytes)"
        self.finish(with: AVPlayerItem(url: file))
        self.startAudioIfAny()
      }
    }
  }

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

  private var statusObserver: NSKeyValueObservation?

  func play() {
    player.play()
    audioPlayer?.play()
  }
  func pause() {
    player.pause()
    audioPlayer?.pause()
  }
  func seek(toMs ms: Int) {
    player.seek(to: CMTime(value: CMTimeValue(ms), timescale: 1000))
  }
  func dispose() {
    player.pause()
    audioPlayer?.pause()
    audioPlayer = nil
    layer.removeFromSuperlayer()

    // The assembled track is a hundred megabytes and is written per playback.
    // Leaving it behind filled the container with copies of the same video.
    if let assembled {
      try? FileManager.default.removeItem(at: assembled)
      self.assembled = nil
    }
    if let audioFile {
      try? FileManager.default.removeItem(at: audioFile)
      self.audioFile = nil
    }
  }

  /// Appends a line to Documents/hdr_state.log.
  ///
  /// A physical device gives no reliable log or stdout channel back to the
  /// machine driving it, and a screenshot can only show one instant. A file in
  /// the app container can be read afterwards and shows the trend.
  private func logDescription(_ fields: [String: Any]) {
    guard let documents = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    ).first else { return }
    let file = documents.appendingPathComponent("hdr_state.log")
    let line = "\(Date().timeIntervalSince1970) \(fields)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: file) {
      handle.seekToEndOfFile()
      handle.write(data)
      try? handle.close()
    } else {
      try? data.write(to: file)
    }
  }

  /// Swaps the HEVC sample entry fourcc from hev1 to hvc1.
  ///
  /// AVFoundation will not play hev1; the difference is only where the
  /// parameter sets live, and hvcC carries them for both.
  static func asHvc1(_ data: Data) -> Data {
    let hev1 = Data("hev1".utf8)
    let hvc1 = Data("hvc1".utf8)
    var out = Data()
    out.reserveCapacity(data.count)
    var rest = data[...]
    while let r = rest.range(of: hev1) {
      out.append(contentsOf: rest[rest.startIndex..<r.lowerBound])
      out.append(hvc1)
      rest = rest[r.upperBound...]
    }
    out.append(contentsOf: rest)
    return out
  }

  /// Plays the DASH audio track on its own player, kept in step with the
  /// video one.
  ///
  /// Muxing the two into an AVMutableComposition does not work for this
  /// content: the video track is HEVC with an hev1 entry, which the
  /// composition pipeline refuses. Two players cost one extra sync point and
  /// nothing else.
  private var audioPlayer: AVPlayer?

  /// Reported to Dart so audio success and failure are distinguishable.
  private(set) var audioNote = "none"

  private func startAudioIfAny() {
    guard let audioUrl else { return }
    let headers = [
      "Referer": "https://www.bilibili.com",
      "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)",
    ]
    DashAssembler.assemble(
      url: audioUrl,
      headers: headers,
      onFragment: { [weak self] done, total in
        DispatchQueue.main.async { self?.audioNote = "fetching \(done)/\(total)" }
      }
    ) { [weak self] result in
      guard let self else { return }
      guard let result, !result.data.isEmpty else {
        DispatchQueue.main.async { self.audioNote = "assemble-failed" }
        return
      }
      let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("audio_\(UUID().uuidString).mp4")
      guard (try? result.data.write(to: file)) != nil else {
        DispatchQueue.main.async { self.audioNote = "write-failed" }
        return
      }
      DispatchQueue.main.async {
        let player = AVPlayer(url: file)
        player.seek(to: self.player.currentTime())
        player.play()
        self.audioPlayer = player
        self.audioFile = file
        self.audioNote = "playing-\(result.data.count)"
      }
    }
  }
  /// What the platform is actually presenting, so the UI can say whether the
  /// picture is HDR rather than assuming it.
  func describe() -> [String: Any] {
    let out = buildDescription()
    logDescription(out)
    return out
  }

  private func buildDescription() -> [String: Any] {
    var out: [String: Any] = [
      "edrRequested": edrRequested,
      "source": sourceNote,
      "audio": audioNote,
      "ready": didBecomeReady,
      // Playback state, so a stalled picture is distinguishable from a paused
      // one without having to guess from a screenshot.
      "rate": player.rate,
      "timeControl": player.timeControlStatus.rawValue,
      "seconds": CMTimeGetSeconds(player.currentTime()),
      "duration": player.currentItem.map {
        CMTimeGetSeconds($0.duration)
      } ?? 0,
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
      // The CMFormatDescription extensions are keyed by the CVImageBuffer
      // constants; "ColorPrimaries"/"TransferFunction" exist but hold nothing.
      let primaries = ext["CVImageBufferColorPrimaries"] as? String
      let transfer = ext["CVImageBufferTransferFunction"] as? String
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

final class HdrContainerView: UIView {
  /// The AVPlayerLayer whose frame has to follow this view.
  ///
  /// A CALayer sublayer does not resize with its superlayer the way a subview
  /// does, so setting the frame once at init left it 0x0: the view was added
  /// but nothing was ever drawn into it.
  var playerLayer: CALayer?

  override func layoutSubviews() {
    super.layoutSubviews()
    playerLayer?.frame = bounds
  }
}

final class HdrVideoPlatformView: NSObject, FlutterPlatformView {
  private let container = HdrContainerView()

  init(frame: CGRect, viewId: Int64, args: [String: Any]) {
    super.init()

    container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    container.backgroundColor = .black
    container.frame = frame

    guard
      let raw = args["url"] as? String,
      let url = URL(string: raw)
    else { return }
    let audioRaw = args["audioUrl"] as? String
    let audioUrl = audioRaw.flatMap { URL(string: $0) }

    let controller = HdrVideoController(url: url, audioUrl: audioUrl)
    HdrVideoPlugin.controllers[viewId] = controller

    container.playerLayer = controller.layer
    controller.layer.frame = container.bounds
    container.layer.addSublayer(controller.layer)
  }

  func view() -> UIView { container }

}
