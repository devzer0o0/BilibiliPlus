import AVFoundation
import Flutter
import UIKit

/// Native HDR playback for iOS.
///
/// Ownership: the Dart controller owns one session per source and creates it
/// over the control channel; the platform view only *attaches* to that session
/// to show its layer. A rebuild, a rotation or a full-screen toggle therefore
/// cannot restart playback - the worst it does is re-attach a layer.
///
/// One AVPlayer plays one AVPlayerItem whose video and audio come from a local
/// HLS presentation assembled from bilibili's DASH tracks. Both tracks share
/// the system clock, so no timer has to chase audio back into sync.
final class HdrVideoPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  static var sessions: [String: HdrVideoSession] = [:]
  static var eventSink: FlutterEventSink?
  static var registrar: FlutterPluginRegistrar?

  static func register(with registrar: FlutterPluginRegistrar) {
    Self.registrar = registrar
    registrar.register(
      HdrVideoViewFactory(messenger: registrar.messenger()),
      withId: "pilipilus/hdr_video"
    )

    let control = FlutterMethodChannel(
      name: "pilipilus/hdr_video/control",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(HdrVideoPlugin(), channel: control)

    let events = FlutterEventChannel(
      name: "pilipilus/hdr_video/events",
      binaryMessenger: registrar.messenger()
    )
    events.setStreamHandler(HdrVideoPlugin())

    sweepStaleFiles()
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    HdrVideoPlugin.eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    HdrVideoPlugin.eventSink = nil
    return nil
  }

  /// Removes files left by an earlier build.
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

  static func broadcast(_ payload: [String: Any]) {
    guard let sink = eventSink else { return }
    DispatchQueue.main.async { sink(payload) }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let sessionId = (args["sessionId"] as? String) ?? ""

    if call.method == "hdrCapability" {
      // Whether this device can present extended range at all. A simulator, or
      // any device without HDR display support, answers 0 - routing a PQ
      // rendition there makes AVFoundation filter out every alternate and the
      // item never becomes ready.
      var modes = 0
      if #available(iOS 17.0, *) {
        modes = AVPlayer.availableHDRModes.rawValue
      }
      result(["availableHdrModes": Int(modes), "supported": modes != 0])
      return
    }

    switch call.method {
    case "createSession":
      close(sessionId)
      guard
        let url = (args["url"] as? String).flatMap({ URL(string: $0) })
      else {
        result(FlutterError(code: "bad_args", message: "url missing", details: nil))
        return
      }
      let audioUrl = (args["audioUrl"] as? String).flatMap { URL(string: $0) }
      let session = HdrVideoSession(
        sessionId: sessionId,
        videoUrl: url,
        audioUrl: audioUrl,
        videoRange: Self.segmentBase(args, "video"),
        audioRange: Self.segmentBase(args, "audio"),
        media: Self.mediaDescription(args),
        startMs: args["startMs"] as? Int ?? 0,
        autoPlay: args["autoPlay"] as? Bool ?? true,
        rate: (args["rate"] as? NSNumber)?.doubleValue ?? 1
      )
      HdrVideoPlugin.sessions[sessionId] = session
      HdrVideoViewRegistry.attachPending(session)
      result(nil)

    case "replaceSource":
      guard let session = HdrVideoPlugin.sessions[sessionId] else {
        result(FlutterError(code: "no_session", message: sessionId, details: nil))
        return
      }
      guard let url = (args["url"] as? String).flatMap({ URL(string: $0) }) else {
        result(FlutterError(code: "bad_args", message: "url missing", details: nil))
        return
      }
      session.replaceSource(
        videoUrl: url,
        audioUrl: (args["audioUrl"] as? String).flatMap { URL(string: $0) },
        videoRange: Self.segmentBase(args, "video"),
        audioRange: Self.segmentBase(args, "audio"),
        media: Self.mediaDescription(args),
        startMs: args["startMs"] as? Int ?? 0,
        autoPlay: args["autoPlay"] as? Bool ?? true,
        rate: (args["rate"] as? NSNumber)?.doubleValue ?? 1
      )
      result(nil)

    case "dispose":
      if sessionId.isEmpty {
        for key in HdrVideoPlugin.sessions.keys { close(key) }
      } else {
        close(sessionId)
      }
      result(nil)

    default:
      // describe() and the per-view commands arrive keyed by the platform view
      // id, while state-changing commands are keyed by the source session.
      // Both resolve to the same session: a view attaches to one session at a
      // time, and the registry is what knows which.
      let targetSession = sessionId.isEmpty
        ? HdrVideoViewRegistry.session(forViewId: args["id"] as? Int ?? -1)
        : HdrVideoPlugin.sessions[sessionId]
      guard let session = targetSession else {
        result(
          FlutterError(
            code: "no_session",
            message: sessionId.isEmpty ? "view \(args["id"] ?? -1)" : sessionId,
            details: nil
          )
        )
        return
      }
      switch call.method {
      case "play":
        session.setPlaying(true)
        result(nil)
      case "pause":
        session.setPlaying(false)
        result(nil)
      case "seek":
        session.seek(toMs: args["ms"] as? Int ?? 0)
        result(nil)
      case "setRate":
        session.setRate((args["rate"] as? NSNumber)?.doubleValue ?? 1)
        result(nil)
      case "describe":
        result(session.describe())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// The rendition's real codec, size and rate, as the playurl response gave it.
  static func mediaDescription(_ args: [String: Any]) -> HdrVideoSession.Media {
    HdrVideoSession.Media(
      videoCodecs: args["videoCodecs"] as? String,
      audioCodecs: args["audioCodecs"] as? String,
      width: args["width"] as? Int,
      height: args["height"] as? Int,
      frameRate: (args["frameRate"] as? String).flatMap(Double.init)
    )
  }

  /// Reads `{ "video": {init, index}, "audio": {...} }` from the call.
  static func segmentBase(_ args: [String: Any], _ key: String) -> DashSegmentBase? {
    guard let raw = args[key] as? [String: Any] else { return nil }
    return DashSegmentBase(
      initialization: raw["init"] as? String,
      indexRange: raw["index"] as? String
    )
  }

  private func close(_ sessionId: String) {
    HlsBridge.trace("session close \(sessionId.prefix(24))")
    HdrVideoPlugin.sessions.removeValue(forKey: sessionId)?.stop()
    HdrVideoViewRegistry.detachSession(sessionId)
  }
}
/// One playback session: an AVPlayerItem fed by the HLS bridge.
final class HdrVideoSession {
  /// What the source actually is. Declared in the HLS master playlist and
  /// checked against the init segment by AVFoundation; a mismatch there fails
  /// the item after the first fragment is fetched.
  struct Media {
    let videoCodecs: String?
    let audioCodecs: String?
    let width: Int?
    let height: Int?
    let frameRate: Double?
  }

  /// The HLS video range for this rendition.
  ///
  /// Ten-bit HEVC is offered as HDR10 (PQ) or HLG; everything else is SDR. The
  /// real transfer function is read back from the format description in
  /// describe(), so this only has to agree with what will actually be decoded.
  static func videoRange(for media: Media) -> String? {
    let codecs = media.videoCodecs ?? ""
    let hevc = codecs.hasPrefix("hev1") || codecs.hasPrefix("hvc1")
    guard hevc else { return "SDR" }
    let tenBit = codecs.contains("hvc1.2") || codecs.contains("hev1.2")
    return tenBit ? "PQ" : "SDR"
  }

  let player = AVPlayer()
  let layer: AVPlayerLayer
  private(set) var sessionId: String
  private var bridge: HlsBridge?
  private var statusObserver: NSKeyValueObservation?
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?

  private var media = Media(
    videoCodecs: nil, audioCodecs: nil, width: nil, height: nil, frameRate: nil
  )
  private var desiredPlaying = true
  private var desiredRate: Double = 1
  private var pendingSeekMs: Int?
  private var disposed = false
  private var ready = false
  private var completed = false
  private var failure: String?
  private var sourceNote = "connecting"
  private var audioNote = "none"
  private var edrRequested = false

  /// Progress is emitted at about 4 Hz; everything else immediately.
  private var lastEmit: CFTimeInterval = 0

  init(
    sessionId: String,
    videoUrl: URL,
    audioUrl: URL?,
    videoRange: DashSegmentBase?,
    audioRange: DashSegmentBase?,
    media: Media,
    startMs: Int,
    autoPlay: Bool,
    rate: Double
  ) {
    self.sessionId = sessionId
    self.media = media
    declaredVideoBase = videoRange
    declaredAudioBase = audioRange
    desiredPlaying = autoPlay
    desiredRate = rate
    pendingSeekMs = startMs > 0 ? startMs : nil
    layer = AVPlayerLayer(player: player)
    layer.videoGravity = .resizeAspect
    if #available(iOS 17.0, *) {
      // A request to the compositor, not proof of HDR. describe() reports the
      // actual format description separately.
      layer.wantsExtendedDynamicRangeContent = true
      edrRequested = true
    }
    open(videoUrl: videoUrl, audioUrl: audioUrl)
  }

  /// Swaps the media on the same player instead of creating a second one.
  func replaceSource(
    videoUrl: URL,
    audioUrl: URL?,
    videoRange: DashSegmentBase?,
    audioRange: DashSegmentBase?,
    media: Media,
    startMs: Int,
    autoPlay: Bool,
    rate: Double
  ) {
    declaredVideoBase = videoRange
    declaredAudioBase = audioRange
    // The replacement rendition's codec/size/rate must be what the new master
    // playlist declares. Leaving `media` alone meant a codec switch kept the
    // old sample-entry description and AVFoundation failed after fragment one.
    self.media = media
    desiredPlaying = autoPlay
    desiredRate = rate
    pendingSeekMs = startMs > 0 ? startMs : nil
    ready = false
    completed = false
    failure = nil
    open(videoUrl: videoUrl, audioUrl: audioUrl)
  }

  private func open(videoUrl: URL, audioUrl: URL?) {
    bridge?.stop()
    bridge = nil
    cancelPreparation()

    // The track's own index says where the initialization segment ends and how
    // long each fragment is. Guessing either (the old loader did) shifted every
    // later fragment by the error.
    //
    // Everything below is asynchronous and cancellable. It used to block on a
    // DispatchSemaphore while the platform channel call that started it was
    // still on the main thread, so a slow index response froze the UI for up to
    // twenty seconds per track.
    let generation = beginPreparation()
    readSegmentBase(videoUrl, declared: declaredVideoBase) { [weak self] videoBase in
      guard let self, self.isCurrent(generation) else { return }
      guard let videoBase else {
        self.fail("no-index")
        return
      }
      self.fetchIndex(videoUrl, videoBase) { [weak self] index in
        guard let self, self.isCurrent(generation) else { return }
        guard let index,
              let videoTrack = self.makeTrack(
                url: videoUrl, base: videoBase, index: index, isAudio: false
              )
        else {
          self.fail("no-index")
          return
        }
        guard let audioUrl else {
          self.startBridge(video: videoTrack, audio: nil)
          return
        }
        self.readSegmentBase(audioUrl, declared: self.declaredAudioBase) {
          [weak self] audioBase in
          guard let self, self.isCurrent(generation) else { return }
          guard let audioBase else {
            self.audioNote = "unsupported"
            self.startBridge(video: videoTrack, audio: nil)
            return
          }
          self.fetchIndex(audioUrl, audioBase) { [weak self] audioIndex in
            guard let self, self.isCurrent(generation) else { return }
            guard let audioIndex,
                  let track = self.makeTrack(
                    url: audioUrl, base: audioBase, index: audioIndex, isAudio: true
                  )
            else {
              self.audioNote = "unsupported"
              self.startBridge(video: videoTrack, audio: nil)
              return
            }
            self.audioNote = "grouped"
            self.startBridge(video: videoTrack, audio: track)
          }
        }
      }
    }
  }

  // MARK: - Preparation cancellation

  private var preparationGeneration = 0
  private var preparationTasks: Set<URLSessionDataTask> = []

  private func beginPreparation() -> Int {
    preparationGeneration &+= 1
    return preparationGeneration
  }

  private func isCurrent(_ generation: Int) -> Bool {
    !disposed && generation == preparationGeneration
  }

  /// Drops every in-flight preparation request and invalidates its callbacks.
  func cancelPreparation() {
    preparationGeneration &+= 1
    for task in preparationTasks { task.cancel() }
    preparationTasks.removeAll()
  }

  private func track(_ task: URLSessionDataTask) {
    preparationTasks.insert(task)
  }

  private func untrack(_ task: URLSessionDataTask) {
    preparationTasks.remove(task)
  }

  private func makeTrack(
    url: URL,
    base: DashSegmentBase,
    index: SegmentIndex,
    isAudio: Bool
  ) -> HlsBridge.Track? {
    // The codec string must match the sample entry in the init segment. A
    // hardcoded "hvc1…" beside an AVC track parses as a playlist and then fails
    // the item after the first fragment.
    return HlsBridge.Track(
      url: url,
      initialization: base.initialization,
      indexRange: base.indexRange,
      index: index,
      codecs: (isAudio ? media.audioCodecs : media.videoCodecs) ??
        (isAudio ? "mp4a.40.2" : "avc1.4d401f"),
      width: isAudio ? nil : media.width,
      height: isAudio ? nil : media.height,
      frameRate: isAudio ? nil : media.frameRate,
      videoRange: isAudio ? nil : HdrVideoSession.videoRange(for: media),
      bandwidth: 0,
      headers: Self.upstreamHeaders
    )
  }

  /// Reads and parses the sidx without blocking any thread.
  ///
  /// The old version waited on a DispatchSemaphore with a 20 second timeout.
  /// It was called from the platform-channel handler on the main thread, so a
  /// slow index response froze the UI instead of merely delaying playback.
  private func fetchIndex(
    _ url: URL,
    _ base: DashSegmentBase,
    completion: @escaping (SegmentIndex?) -> Void
  ) {
    let request = Self.rangedRequest(url, base.indexRange)
    var task: URLSessionDataTask?
    task = URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
      if let self, let finished = task { self.untrack(finished) }
      if error != nil {
        completion(nil)
        return
      }
      guard let data, !data.isEmpty, let parsed = try? SidxParser.parse(data) else {
        completion(nil)
        return
      }
      completion(parsed)
    }
    if let task {
      track(task)
      task.resume()
    } else {
      completion(nil)
    }
  }

  /// The ranges the playurl response already declared, when the caller had them.
  private var declaredVideoBase: DashSegmentBase?
  private var declaredAudioBase: DashSegmentBase?

  private func readSegmentBase(
    _ url: URL,
    declared: DashSegmentBase?,
    completion: @escaping (DashSegmentBase?) -> Void
  ) {
    if let declared {
      // The service told us exactly where the init segment and the index are;
      // discovering them again can only disagree with the server.
      completion(declared)
      return
    }
    // ftyp + moov + sidx live at the front of the track; one ranged read of the
    // first 8 KiB finds where each box ends.
    let request = Self.rangedRequest(url, 0...8191)
    var task: URLSessionDataTask?
    task = URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
      if let self, let finished = task { self.untrack(finished) }
      guard error == nil, let data, !data.isEmpty else {
        completion(nil)
        return
      }
      completion(HdrVideoSession.discoverSegmentBase(in: data))
    }
    if let task {
      track(task)
      task.resume()
    } else {
      completion(nil)
    }
  }

  /// Reads the segment base out of the file head.
  ///
  /// Walks box headers instead of scanning for byte patterns and stops at the
  /// first media box, so frame data can never be mistaken for an index.
  static func discoverSegmentBase(in head: Data) -> DashSegmentBase? {
    let bytes = [UInt8](head)
    var offset = 0
    var headerEnd = 0
    var sawSidx = false
    while offset + 8 <= bytes.count {
      let size = Int(
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
          | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
      )
      let type = String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? ""
      guard size >= 8, offset + size <= bytes.count else { break }
      offset += size
      if type == "sidx" {
        sawSidx = true
        headerEnd = offset
        break
      }
      if type == "mdat" { break }
    }
    guard sawSidx, headerEnd > 0 else { return nil }
    return DashSegmentBase(
      initialization: "0-\(headerEnd - 1)",
      indexRange: "0-\(headerEnd - 1)"
    )
  }

  private func startBridge(video: HlsBridge.Track, audio: HlsBridge.Track?) {
    let bridge = HlsBridge(video: video, audio: audio)
    do {
      let port = try bridge.start()
      guard let url = URL(string: "http://127.0.0.1:\(port)/\(bridge.token)/master.m3u8")
      else {
        fail("bad-url")
        return
      }
      self.bridge = bridge
      sourceNote = "hls segments=\(video.index?.references.count ?? 0)"
      attach(AVPlayerItem(url: url))
    } catch {
      fail("bridge-failed")
    }
  }

  private func attach(_ item: AVPlayerItem) {
    statusObserver?.invalidate()
    statusObserver = item.observe(\.status) { [weak self] observed, _ in
      guard let self, !self.disposed else { return }
      switch observed.status {
      case .readyToPlay:
        self.ready = true
        self.applyIntent()
        self.emit(force: true)
      case .failed:
        self.fail(observed.error?.localizedDescription ?? "item-failed")
      default:
        break
      }
    }
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      guard let self, !self.disposed else { return }
      self.completed = true
      self.emit(force: true)
    }
    player.replaceCurrentItem(with: item)

    if timeObserver == nil {
      timeObserver = player.addPeriodicTimeObserver(
        forInterval: CMTime(value: 1, timescale: 4),
        queue: .main
      ) { [weak self] _ in
        guard let self, !self.disposed else { return }
        self.resumeIfStalled()
        self.emit()
      }
    }
  }

  /// Applies the user's intent, not the player's momentary state.
  ///
  /// The old path called play() from the load completion handler, which undid a
  /// pause issued while the item was still preparing.
  private func applyIntent() {
    if let ms = pendingSeekMs {
      pendingSeekMs = nil
      player.seek(
        to: CMTime(value: CMTimeValue(ms), timescale: 1000),
        toleranceBefore: .zero,
        toleranceAfter: .zero
      )
    }
    if desiredPlaying && !completed {
      player.play()
      player.rate = Float(desiredRate)
    } else {
      player.pause()
    }
  }

  /// Recovers from a stall the way intent would, without overriding it.
  private func resumeIfStalled() {
    guard ready, !completed, desiredPlaying else { return }
    guard player.currentItem?.status == .readyToPlay else { return }
    if player.timeControlStatus == .paused {
      player.play()
      player.rate = Float(desiredRate)
    }
  }

  func setPlaying(_ playing: Bool) {
    HlsBridge.trace("setPlaying \(playing) ready=\(ready)")
    desiredPlaying = playing
    if playing { completed = false }
    if ready { applyIntent() }
    emit(force: true)
  }

  func setRate(_ rate: Double) {
    desiredRate = rate
    if ready {
      player.rate = Float(rate)
      if desiredPlaying { player.play() }
    }
    emit(force: true)
  }

  func seek(toMs ms: Int) {
    completed = false
    guard ready else {
      // Remembered, not dropped: this is the seek that used to be lost when it
      // arrived during preparation.
      pendingSeekMs = ms
      return
    }
    player.seek(
      to: CMTime(value: CMTimeValue(ms), timescale: 1000),
      toleranceBefore: .zero,
      toleranceAfter: .zero
    )
    emit(force: true)
  }

  func stop() {
    if disposed { return }
    disposed = true
    cancelPreparation()
    statusObserver?.invalidate()
    statusObserver = nil
    if let timeObserver {
      player.removeTimeObserver(timeObserver)
      self.timeObserver = nil
    }
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
      self.endObserver = nil
    }
    player.pause()
    player.replaceCurrentItem(with: nil)
    layer.removeFromSuperlayer()
    bridge?.stop()
    bridge = nil
  }

  private func fail(_ reason: String) {
    failure = reason
    sourceNote = reason
    emit(force: true)
  }

  static let upstreamHeaders = [
    "Referer": "https://www.bilibili.com",
    "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)",
  ]

  static func rangedRequest(_ url: URL, _ range: ClosedRange<Int>) -> URLRequest {
    var request = URLRequest(url: url)
    request.setValue(
      "bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range"
    )
    for (key, value) in upstreamHeaders {
      request.setValue(value, forHTTPHeaderField: key)
    }
    request.timeoutInterval = 30
    return request
  }

  /// Emits the snapshot the UI renders.
  ///
  /// Position, duration and rate come from one read, so Dart's two time fields
  /// are one number converted once.
  private func emit(force: Bool = false) {
    if disposed { return }
    let now = CACurrentMediaTime()
    if !force, now - lastEmit < 0.25 { return }
    lastEmit = now
    let seconds = CMTimeGetSeconds(player.currentTime())
    let duration = player.currentItem.map { CMTimeGetSeconds($0.duration) } ?? 0
    var state: [String: Any] = [
      "seconds": seconds.isFinite ? seconds : 0,
      "duration": duration.isFinite ? duration : 0,
      "rate": player.rate,
      "ready": ready,
      "completed": completed,
      "timeControl": player.timeControlStatus.rawValue,
    ]
    if let failure { state["error"] = failure }
    HdrVideoPlugin.broadcast([
      "event": "state",
      "sessionId": sessionId,
      "state": state,
    ])
  }

  /// Persists one description line so a device with no console relay can still
  /// be inspected afterwards.
  ///
  /// Opt-in and bounded: only when `PILIPLUS_HDR_TRACE` is set, only the
  /// fields describe() already exposes (never URLs or credentials), and only
  /// while a session exists. It is skipped in release builds entirely.
  private static var traceWritten = 0
  /// One bounded NSLog line per description, only when the caller opted in.
  ///
  /// The device has no console relay over SSH and the release build must not
  /// write files, so the trace is an opt-in environment variable and nothing
  /// else: no URLs, no credentials, and at most 200 lines per run.
  private func traceDescription(_ fields: [String: Any]) {
    // Compile-time gate AND runtime opt-in. Release builds do not contain the
    // call at all, so setting the environment variable there cannot re-enable
    // it; profile/debug still need the variable because the trace is a test
    // tool, not a product feature.
    #if PILIPLUS_DIAGNOSTICS
    guard ProcessInfo.processInfo.environment["PILIPLUS_HDR_TRACE"] == "1",
          HdrVideoSession.traceWritten < 200
    else { return }
    HdrVideoSession.traceWritten += 1
    NSLog("[hdr] %@", "\(fields)")
    #endif
  }

  /// What the platform is actually presenting.
  ///
  /// Separate from the state stream: a tinted screenshot and an EDR request say
  /// nothing about whether HDR is composited.
  func describe() -> [String: Any] {
    var out: [String: Any] = [
      "edrRequested": edrRequested,
      "source": sourceNote,
      "audio": audioNote,
      "ready": ready,
      "rate": player.rate,
      "seconds": CMTimeGetSeconds(player.currentTime()),
      "duration": player.currentItem.map { CMTimeGetSeconds($0.duration) } ?? 0,
    ]
    if #available(iOS 17.0, *) {
      out["availableHdrModes"] = AVPlayer.availableHDRModes.rawValue
    }
    guard let item = player.currentItem else {
      traceDescription(out)
      return out
    }
    let size = item.presentationSize
    out["width"] = Int(size.width)
    out["height"] = Int(size.height)
    guard
      let track = item.tracks.first(where: { $0.assetTrack?.mediaType == .video }),
      let assetTrack = track.assetTrack
    else {
      traceDescription(out)
      return out
    }
    let described = Self.describeFormats(assetTrack, into: out)
    traceDescription(described)
    return described
  }

  static func describeFormats(_ track: AVAssetTrack, into out: [String: Any]) -> [String: Any] {
    var out = out
    let descriptions = (track.formatDescriptions as? [CMFormatDescription]) ?? []
    guard let format = descriptions.first else { return out }
    if let ext = CMFormatDescriptionGetExtensions(format) as? [String: Any] {
      let primaries = ext["CVImageBufferColorPrimaries"] as? String
      let transfer = ext["CVImageBufferTransferFunction"] as? String
      out["primaries"] = primaries
      out["transfer"] = transfer
      // PQ (HDR10) and HLG are the extended-range transfer functions the
      // catalogue serves; anything else is SDR. Ten-bit alone is not HDR.
      out["hdr"] = (transfer?.contains("2084") == true)
        || (transfer?.contains("HLG") == true)
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
    HdrVideoPlatformView(frame: frame, viewId: viewId, args: args as? [String: Any] ?? [:])
  }
}

/// Attaches views to sessions.
///
/// A view and its session have independent lifetimes: the session is created by
/// the controller before any surface exists, and a surface can be destroyed and
/// recreated (rotation, full screen) without touching playback.
enum HdrVideoViewRegistry {
  /// Weak, because a registry that owns its views keeps them alive forever:
  /// the platform view's deinit is what would remove the entry, and a strong
  /// reference is exactly what prevents that deinit from ever running.
  private static var views: [Int64: WeakView] = [:]

  final class WeakView {
    weak var value: HdrVideoPlatformView?
    init(_ value: HdrVideoPlatformView) { self.value = value }
  }

  /// Live views, with dead entries swept on every access.
  static var liveViews: [HdrVideoPlatformView] {
    views = views.filter { $0.value.value != nil }
    return views.values.compactMap { $0.value }
  }

  static func register(_ view: HdrVideoPlatformView, viewId: Int64) {
    views = views.filter { $0.value.value != nil }
    views[viewId] = WeakView(view)
  }

  /// Explicit removal. Deinit is not enough on its own: a view can be detached
  /// from its window without being deallocated immediately, and a stale entry
  /// would keep answering commands for a session nobody is displaying.
  static func unregister(viewId: Int64) {
    views.removeValue(forKey: viewId)
  }

  static func attachPending(_ session: HdrVideoSession) {
    for view in liveViews where view.pendingSessionId == session.sessionId {
      view.attach(session)
    }
  }

  static func detachSession(_ sessionId: String) {
    for view in liveViews where view.attachedSessionId == sessionId {
      view.detach()
    }
  }

  /// The session a platform view is currently showing, if any.
  static func session(forViewId viewId: Int) -> HdrVideoSession? {
    guard let attached = views[Int64(viewId)]?.value?.attachedSessionId else {
      return nil
    }
    return HdrVideoPlugin.sessions[attached]
  }

  static var count: Int {
    views = views.filter { $0.value.value != nil }
    return views.count
  }
}

final class HdrContainerView: UIView {
  var playerLayer: CALayer?

  override func layoutSubviews() {
    super.layoutSubviews()
    // A CALayer sublayer does not follow its superlayer the way a subview does.
    playerLayer?.frame = bounds
  }

  /// Let touches reach the Flutter controls stacked above.
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    nil
  }
}

final class HdrVideoPlatformView: NSObject, FlutterPlatformView {
  private let container = HdrContainerView()
  private let viewId: Int64
  /// The session this view was created for; it may not exist yet.
  let pendingSessionId: String
  private(set) var attachedSessionId: String?

  init(frame: CGRect, viewId: Int64, args: [String: Any]) {
    self.viewId = viewId
    pendingSessionId = args["sessionId"] as? String ?? ""
    super.init()

    container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    container.backgroundColor = .black
    container.frame = frame

    HdrVideoViewRegistry.register(self, viewId: viewId)
    if let session = HdrVideoPlugin.sessions[pendingSessionId] {
      attach(session)
    }
  }

  func attach(_ session: HdrVideoSession) {
    if attachedSessionId == session.sessionId { return }
    detachLayer()
    session.layer.frame = container.bounds
    container.playerLayer = session.layer
    container.layer.addSublayer(session.layer)
    attachedSessionId = session.sessionId
  }

  func detach() {
    detachLayer()
    attachedSessionId = nil
  }

  /// Removes the layer only when this container really owns it.
  ///
  /// Unbinding an old view used to call `removeFromSuperlayer` on whatever
  /// layer field it held, including one a newer view had already adopted - the
  /// picture then vanished from the new surface with no error anywhere.
  private func detachLayer() {
    guard let layer = container.playerLayer else { return }
    if layer.superlayer === container.layer {
      layer.removeFromSuperlayer()
    }
    container.playerLayer = nil
  }

  deinit {
    HdrVideoViewRegistry.unregister(viewId: viewId)
    detachLayer()
  }

  func view() -> UIView { container }
}
