import AVFoundation
import AVKit
import CoreMedia
import Flutter
import UIKit
import VideoToolbox

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
    // Records that the channel is live at all. Without this, a method call that
    // returns to Dart and produces no further trace cannot be told apart from a
    // handler that was never entered.
    PlaybackDiagnostics.shared.sample([
      "stage": "handle",
      "detail": call.method,
    ])

    if call.method == "codecCapability" {
      // Which sample entries this device can hand to a hardware decoder.
      //
      // The app otherwise has to guess: it preferred AV1 everywhere, and on a
      // build whose Avcodec lacks the AV1 VideoToolbox backport mpv silently
      // decoded a 2160p stream on the CPU (`hwdec=no` in every sample). Asking
      // VideoToolbox directly is what lets the codec order match reality
      // instead of the catalogue.
      result([
        "av1": VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1),
        "hevc": VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
        "h264": VTIsHardwareDecodeSupported(kCMVideoCodecType_H264),
      ])
      return
    }

    if call.method == "av1DecoderProbe" {
      // What the loaded FFmpeg can do for AV1, asked of the loaded FFmpeg.
      // Separate from `codecCapability` above, which only asks the chip: a
      // device that answers "yes" there still decodes on the CPU when the app
      // shipped the stock Avcodec.
      result(Av1DecoderProbe.describe())
      return
    }

    if call.method == "hdrCapability" {
      // Whether this device can present extended range at all. A simulator, or
      // any device without HDR display support, answers 0 - routing a PQ
      // rendition there makes AVFoundation filter out every alternate and the
      // item never becomes ready.
      // Two different questions:
      //
      //  * `eligibleForHDRPlayback` - this *device model* could play HDR.
      //    True on a simulator running on an HDR-capable Mac, and true on a
      //    phone whose panel is HDR, regardless of what is on screen now.
      //  * `availableHDRModes` - this *output path* can present it right now.
      //    Zero on a simulator, and zero on a device whose display settings
      //    currently disable HDR.
      //
      // Presenting needs the second. Using eligibility alone routed the PQ
      // rendition to AVPlayerLayer on a simulator, where it decodes but the
      // picture freezes - measured, not assumed.
      var modes = 0
      var modesKnown = false
      if #available(iOS 17.0, *) {
        modes = AVPlayer.availableHDRModes.rawValue
        modesKnown = true
      }
      let capability = HdrCapability(
        eligible: AVPlayer.eligibleForHDRPlayback,
        modes: modes,
        modesKnown: modesKnown
      )
      result([
        "availableHdrModes": Int(modes),
        "eligibleForHdrPlayback": capability.eligible,
        "supported": capability.canPresent,
        "reason": capability.reason ?? "",
      ])
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
      case "setInterrupted":
        // A PiP control, an audio interruption or a call owns the intent while
        // it lasts; the session must not resume over it.
        session.interrupted = args["interrupted"] as? Bool ?? false
        session.setPlaying(!(args["interrupted"] as? Bool ?? false))
        result(nil)
      case "pipStart":
        if let failure = session.startPip() {
          result(
            FlutterError(code: "pip_failed", message: failure, details: nil)
          )
        } else {
          result(nil)
        }
      case "pipStop":
        session.stopPip()
        result(nil)
      case "setAudioOnly":
        let enabled = args["audioOnly"] as? Bool ?? false
        if session.setAudioOnly(enabled) {
          result(nil)
        } else {
          result(
            FlutterError(
              code: "audio_only_unsupported",
              message: "no separate audio track",
              details: nil
            )
          )
        }
      case "captureFrame":
        result(session.captureFrame())
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
      frameRate: (args["frameRate"] as? String).flatMap(Double.init),
      quality: args["quality"] as? Int,
      declaredVideoRange: args["videoRange"] as? String
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
final class HdrVideoSession: NSObject {
  /// What the source actually is. Declared in the HLS master playlist and
  /// checked against the init segment by AVFoundation; a mismatch there fails
  /// the item after the first fragment is fetched.
  struct Media {
    let videoCodecs: String?
    let audioCodecs: String?
    let width: Int?
    let height: Int?
    let frameRate: Double?
    /// The catalogue's quality id, which is what says whether this rendition is
    /// an HDR rung when the init segment carries no `colr` box.
    let quality: Int?
    /// VIDEO-RANGE the caller already established for this rendition (SDR, PQ,
    /// HLG), or nil when it is not known. Never invented here.
    let declaredVideoRange: String?
  }

  /// What the codec string alone can justify - no more.
  ///
  /// The old version mapped "HEVC Main10" to PQ and everything else to SDR.
  /// Both halves were wrong: 10-bit is not a transfer function (10-bit SDR
  /// exists, and Bilibili ships HLG as well as PQ), and a non-HEVC stream can
  /// be HDR too (AV1 HDR is served). A codec string cannot tell us the transfer
  /// function, so when it cannot, the answer is nil and the master playlist
  /// declares nothing rather than guessing.
  ///
  /// The authoritative answer comes from the format description once the item
  /// is ready (see describeFormats); this only has to avoid *asserting* a range
  /// the media did not claim.
  static func videoRange(for media: Media) -> String? {
    // Dolby Vision and HLG rungs arrive with a range the caller already
    // established; anything else is left undeclared and read back from the
    // track once it is decoded. No codec string is turned into a range.
    media.declaredVideoRange
  }

  let player = AVPlayer()
  let layer: AVPlayerLayer

  /// Native PiP for this session, created lazily once the layer is attached.
  private var pip: AVPictureInPictureController?
  private var pipPossibleObservation: NSKeyValueObservation?

  /// A frame extracted from the current item, encoded as SDR PNG.
  ///
  /// Uses `AVPlayerItemVideoOutput` - the public API that copies the item's
  /// current pixel buffer without a second player and without disturbing the
  /// layer. The result is tone mapped to SDR and tagged BT.709, so a PQ/HLG
  /// frame does not end up stored as if its 10-bit code values were ordinary
  /// 8-bit RGB.
  ///
  /// Returns nil when the item is not ready, when the buffer is not available
  /// within a short bound, or when the content is protected.
  func captureFrame() -> [String: Any]? {
    guard ready, !disposed, let item = player.currentItem else { return nil }
    guard item.status == .readyToPlay else { return nil }
    guard item.asset.hasProtectedContent == false else {
      return ["error": "protected"]
    }
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String:
        Int(kCVPixelFormatType_32BGRA),
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ])
    item.add(output)
    defer { item.remove(output) }

    let time = player.currentTime()
    // A paused player has no new frame to hand over; copy the one on screen.
    let target = player.timeControlStatus == .paused
      ? CMTime(value: time.value, timescale: time.timescale)
      : time
    guard output.hasNewPixelBuffer(forItemTime: target) ||
            player.timeControlStatus == .paused
    else { return nil }
    guard let buffer = output.copyPixelBuffer(
      forItemTime: target,
      itemTimeForDisplay: nil
    ) else { return nil }

    let ci = CIImage(cvPixelBuffer: buffer)
    // Convert to sRGB with the source's own colour space: tone mapping happens
    // here, not by reinterpreting PQ code values as gamma-encoded bytes.
    let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let context = CIContext(options: [.workingColorSpace: srgb])
    guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
    let image = UIImage(cgImage: cg)
    guard let png = image.pngData() else { return nil }
    return [
      "png": FlutterStandardTypedData(bytes: png),
      "width": Int(cg.width),
      "height": Int(cg.height),
      "frameMs": Int(CMTimeGetSeconds(time) * 1000),
      "colorSpace": "sRGB",
      "toneMapped": media.declaredVideoRange != nil
        && media.declaredVideoRange != "SDR",
    ]
  }

  /// Whether the platform can offer PiP for this session at all.
  var pipAvailable: Bool {
    AVPictureInPictureController.isPictureInPictureSupported()
  }

  var pipActive: Bool { pip?.isPictureInPictureActive ?? false }
  private(set) var sessionId: String
  private var bridge: HlsBridge?
  private var statusObserver: NSKeyValueObservation?
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?

  private var media = Media(
    videoCodecs: nil,
    audioCodecs: nil,
    width: nil,
    height: nil,
    frameRate: nil,
    quality: nil,
    declaredVideoRange: nil
  )
  /// Audio-only presentation: one AVPlayer, one item, no video track.
  private var audioOnly = false
  private var currentVideoUrl: URL?
  private var currentAudioUrl: URL?

  /// Colour description read from the video init segment, when it carried one.
  ///
  /// This is the only authoritative source for VIDEO-RANGE: the codec string
  /// cannot distinguish PQ from HLG, and guessing is what left the device
  /// treating HDR as SDR.
  /// Set from the init segment currently being prepared, then read back when
  /// the track is built.
  ///
  /// This used to be a single static shared by every session. It was never
  /// cleared, so the range of the previous video leaked into the next one: a
  /// Dolby Vision profile-5 track inherited `HLG` from the HLG clip played
  /// before it, AVFoundation found the declaration contradicting the bitstream
  /// and refused the item with CoreMediaErrorDomain -12927, leaving the player
  /// on its loading state forever.
  ///
  /// The value now belongs to one session and one preparation.
  var describedRange: String?
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

  // MARK: - Stall accounting
  //
  // A stutter is invisible in a screenshot. These record what the player did
  // over the session so "it is janky" becomes a number: how long the item spent
  // waiting to play, how many times it stalled and recovered, and how far the
  // clock fell behind wall time while it was nominally playing.

  /// Total seconds spent with the player waiting (buffer starvation included).
  private var stalledSeconds: Double = 0
  /// Number of transitions into waitingToPlayAtSpecifiedRate.
  private var stallCount = 0
  /// Largest single stall, in milliseconds.
  private var longestStallMs: Int = 0
  /// Cumulative media time advanced (for an effective-rate comparison).
  private var playedSeconds: Double = 0
  /// Wall time since the first item became ready.
  private var wallStart: CFTimeInterval?
  private var lastSampleTime: CFTimeInterval = 0
  private var lastSamplePosition: Double = 0
  private var wasWaiting = false
  private var waitStart: CFTimeInterval = 0

  /// Samples the player clock. Called from the periodic observer, so it never
  /// adds a timer of its own.
  private func sampleStall() {
    guard ready, !disposed else { return }
    let now = CACurrentMediaTime()
    if wallStart == nil {
      wallStart = now
      lastSampleTime = now
      lastSamplePosition = CMTimeGetSeconds(player.currentTime())
    }
    let position = CMTimeGetSeconds(player.currentTime())
    if position.isFinite, lastSamplePosition.isFinite,
       position >= lastSamplePosition,
       player.timeControlStatus == .playing {
      playedSeconds += position - lastSamplePosition
    }
    lastSamplePosition = position.isFinite ? position : lastSamplePosition
    lastSampleTime = now

    let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    if waiting && !wasWaiting {
      stallCount += 1
      waitStart = now
    } else if !waiting && wasWaiting {
      let duration = now - waitStart
      stalledSeconds += duration
      longestStallMs = max(longestStallMs, Int(duration * 1000))
    }
    wasWaiting = waiting
  }

  /// Writes one rate-limited sample of playback health to the app container.
  ///
  /// This is what makes a device stutter measurable without a console: the host
  /// pulls the file instead of watching a log stream.
  private func recordDiagnostics() {
    var fields = stallReport
    fields["pos"] = Int(CMTimeGetSeconds(player.currentTime()) * 1000)
    fields["ready"] = ready
    if let bridge { fields["brSeg"] = bridge.counterSnapshot()["segments"] ?? 0 }
    PlaybackDiagnostics.shared.sample(fields)
  }

  /// Stall counters, for describe() and the device-measurement entry point.
  var stallReport: [String: Any] {
    let wall = wallStart.map { CACurrentMediaTime() - $0 } ?? 0
    let effective = wall > 0 ? playedSeconds / wall : 0
    return [
      "stallCount": stallCount,
      "stalledSeconds": (stalledSeconds * 1000).rounded() / 1000,
      "longestStallMs": longestStallMs,
      "playedSeconds": (playedSeconds * 1000).rounded() / 1000,
      "wallSeconds": (wall * 1000).rounded() / 1000,
      "effectiveRate": (effective * 1000).rounded() / 1000,
      "waitingForData": player.reasonForWaitingToPlay != nil,
    ]
  }

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
    // This item is served from a loopback bridge that a receiver on the network
    // cannot reach. Leaving external playback at its default means AirPlay
    // video is *attempted* and then fails with a picture-less receiver, which
    // looks like a bug in playback. Refusing it explicitly, while keeping audio
    // route changes working, is the honest capability statement.
    player.allowsExternalPlayback = false
    if #available(iOS 17.0, *) {
      // A request to the compositor, not proof of HDR. describe() reports the
      // actual format description separately.
      layer.wantsExtendedDynamicRangeContent = true
      edrRequested = true
    }
    super.init()
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
    // Remembered so an audio-only switch can rebuild the presentation from the
    // same media without asking the caller for the playurl again.
    currentVideoUrl = videoUrl
    currentAudioUrl = audioUrl
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
    stage("open", "declaredVideo=\(declaredVideoBase != nil)")
    readSegmentBase(videoUrl, declared: declaredVideoBase) { [weak self] videoBase in
      guard let self, self.isCurrent(generation) else { return }
      guard let videoBase else {
        self.fail("no-index")
        return
      }
      self.stage("video-base", "init=\(videoBase.initialization)")
      self.readColorDescription(videoUrl, videoBase) { [weak self] in
      guard let self, self.isCurrent(generation) else { return }
      self.fetchIndex(videoUrl, videoBase) { [weak self] index in
        guard let self, self.isCurrent(generation) else { return }
        self.stage("video-index", "refs=\(index?.references.count ?? -1)")
        guard let index,
              let videoTrack = self.makeTrack(
                url: videoUrl, base: videoBase, index: index, isAudio: false
              )
        else {
          self.fail("no-index")
          return
        }
        self.stage("video-track", "range=\(videoTrack.videoRange ?? "nil")")
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
  }

  /// Last-resort range for a ten-bit stream whose init segment carries no colr
  /// box.
  ///
  /// Measured on device: this 4K/HDR clip's video init segment is 1113 bytes with
  /// no colr box, so both the media read and the caller's declaration are empty.
  /// The playlist then declared no VIDEO-RANGE, AVFoundation parsed a PQ stream
  /// as SDR, and the item failed with CoreMediaErrorDomain -12927.
  ///
  /// This does not overrule real metadata - it only runs when there is none, and
  /// it is limited to HEVC/AV1 ten-bit, which the catalogue serves as HDR. A
  /// 10-bit SDR clip would be mislabelled by it; that is why the media read and
  /// the caller come first, and why the choice is recorded in the diagnostics.
  /// Delegates to [ColorDescription.rangeWhenUnknown], which is where the rule
  /// is unit-tested; this wrapper only supplies the media fields.
  static func codecRangeForTenBit(_ media: Media) -> String? {
    ColorDescription.rangeWhenUnknown(
      codecs: media.videoCodecs,
      quality: media.quality
    )
  }

  /// Which `VIDEO-RANGE` the playlist should declare.
  ///
  /// Order matters, and Dolby Vision inverts it: the sample entry is definitive
  /// for `dvh1` / `dvhe`, while the `colr` box read from the init segment is
  /// not. Measured on a profile-5 title, that box reported HLG; declaring HLG
  /// for a PQ stream made AVFoundation reject the item (-12927) and the player
  /// never left its loading state.
  ///
  /// For everything else the `colr` box stays authoritative - it is what fixed
  /// the earlier case of a PQ stream declared SDR.
  static func resolvedVideoRange(described: String?, media: Media) -> String? {
    if let dolby = codecRangeForDolby(media) { return dolby }
    return described
      ?? HdrVideoSession.videoRange(for: media)
      ?? codecRangeForTenBit(media)
  }

  /// PQ for a Dolby Vision sample entry, nil for anything else.
  static func codecRangeForDolby(_ media: Media) -> String? {
    guard let codecs = media.videoCodecs, !codecs.isEmpty else { return nil }
    let dolby = codecs.hasPrefix("dvh1") || codecs.hasPrefix("dvhe")
    return dolby ? "PQ" : nil
  }
  /// Reports the range read from the media, so a device log can show whether the
  /// playlist declared one. Debug/profile only; compiled out of release.
  static func traceColor(_ range: String?) {
    #if PILIPLUS_DIAGNOSTICS
    NSLog("[hdr] colr VIDEO-RANGE=%@", range ?? "unspecified")
    #endif
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
      // Read from the init segment's colr box when it has one; the caller's
      // declared range is only a fallback. Measured on a device: with no
      // VIDEO-RANGE in the playlist, AVFoundation logged the variant without a
      // range and treated a PQ stream as SDR.
      videoRange: isAudio
        ? nil
        : Self.resolvedVideoRange(described: describedRange, media: media),
      bandwidth: 0,
      headers: Self.upstreamHeaders
    )
  }

  /// Reads and parses the sidx without blocking any thread.
  ///
  /// The old version waited on a DispatchSemaphore with a 20 second timeout.
  /// It was called from the platform-channel handler on the main thread, so a
  /// slow index response froze the UI instead of merely delaying playback.
  /// Reads the video init segment and records its colour description.
  ///
  /// Bounded (one ranged read of the declared initialization range, capped) and
  /// cancellable; a failure leaves the range unknown rather than asserting SDR.
  private func readColorDescription(
    _ url: URL,
    _ base: DashSegmentBase,
    completion: @escaping () -> Void
  ) {
    var request = URLRequest(url: url)
    let range = base.initialization
    request.setValue("bytes=\(range)", forHTTPHeaderField: "Range")
    for (key, value) in Self.upstreamHeaders {
      request.setValue(value, forHTTPHeaderField: key)
    }
    request.timeoutInterval = 20
    var task: URLSessionDataTask?
    task = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
      guard let self else {
        completion()
        return
      }
      if let finished = task { self.untrack(finished) }
      if let data, !data.isEmpty {
        // Scoped to this session: the previous video's range must not describe
        // this one.
        self.describedRange = ColorDescription.read(data)?.videoRange
        HdrVideoSession.traceColor(self.describedRange)
      }
      completion()
    }
    if let task {
      track(task)
      task.resume()
    } else {
      completion()
    }
  }

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
    // Audio-only needs the audio track; without one there is nothing to play,
    // so the request is refused instead of silently playing the video.
    if audioOnly {
      guard let audio else {
        fail("audio-only-unsupported")
        return
      }
      let bridge = HlsBridge(video: video, audio: audio)
      bridge.presentation = .audioOnly
      start(bridge: bridge, video: video)
      return
    }
    let bridge = HlsBridge(video: video, audio: audio)

    start(bridge: bridge, video: video)
  }

  private func start(bridge: HlsBridge, video: HlsBridge.Track) {
    do {
      let port = try bridge.start()
      guard let url = URL(string: "http://127.0.0.1:\(port)/\(bridge.token)/master.m3u8")
      else {
        fail("bad-url")
        return
      }
      self.bridge = bridge
      sourceNote = "hls segments=\(video.index?.references.count ?? 0)"
      stage("bridge-up", "port=\(port) segs=\(video.index?.references.count ?? 0)")
      attach(AVPlayerItem(url: url))
    } catch {
      stage("bridge-error", "\(error)")
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
        PlaybackDiagnostics.shared.begin(sessionId: self.sessionId)
        self.stage("item-ready", "tracks=\(observed.tracks.count)")
        self.applyIntent()
        self.emit(force: true)
      case .failed:
        self.fail(observed.error?.localizedDescription ?? "item-failed")
      default:
        // .unknown is the state a playlist that never resolves sits in, so it
        // must be visible: silence here is what made "still loading" invisible.
        self.stage("item-status", "\(observed.status.rawValue)")
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
    preparePip()

    if timeObserver == nil {
      timeObserver = player.addPeriodicTimeObserver(
        forInterval: CMTime(value: 1, timescale: 4),
        queue: .main
      ) { [weak self] _ in
        guard let self, !self.disposed else { return }
        self.resumeIfStalled()
        self.sampleStall()
        self.recordDiagnostics()
        self.emit()
      }
    }
  }

  /// Creates the PiP controller for the same AVPlayerLayer.
  ///
  /// No second player: PiP hands the existing layer to the system, so audio,
  /// video and the clock stay the ones this session already owns. Creating the
  /// controller per session (not per view) is what lets the picture survive the
  /// view being unbound while PiP is open.
  private func preparePip() {
    guard pip == nil, pipAvailable else { return }
    guard let controller = AVPictureInPictureController(playerLayer: layer) else {
      return
    }
    controller.delegate = self
    if #available(iOS 14.2, *) {
      controller.canStartPictureInPictureAutomaticallyFromInline = false
    }
    pip = controller
  }

  /// Starts PiP. Returns the failure reason, or nil when it started.
  func startPip() -> String? {
    guard let pip else { return "unsupported" }
    guard pip.isPictureInPicturePossible else { return "not-possible" }
    pip.startPictureInPicture()
    return nil
  }

  func stopPip() {
    pip?.stopPictureInPicture()
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
  ///
  /// The distinction that was missing: a pause the *system* asked for - the PiP
  /// window's own pause button, an audio interruption, a call - is
  /// indistinguishable from a stall if the only evidence is
  /// `timeControlStatus == .paused`. Playing again on the next tick therefore
  /// fought the user's PiP control. A stall is now recognised by the reason the
  /// player reports, not by the mere fact that it is paused.
  private func resumeIfStalled() {
    guard ready, !completed, desiredPlaying, !interrupted else { return }
    guard player.currentItem?.status == .readyToPlay else { return }
    guard player.timeControlStatus == .paused else { return }
    // .toPlayPaused means the player wanted to play but is waiting on data.
    // Anything else (paused, or a rate the system set) is not ours to override.
    guard player.reasonForWaitingToPlay != nil else { return }
    player.play()
    player.rate = Float(desiredRate)
  }

  /// Set while something outside this session owns the playback intent.
  var interrupted = false

  /// Switches to an audio-only (or back to audiovisual) presentation.
  ///
  /// One player, one item: the same AVPlayer swaps its item, and the position,
  /// rate and intent are carried across so "听视频" does not restart the video.
  /// Returns false when the source has no separate audio track, in which case
  /// nothing is changed.
  func setAudioOnly(_ enabled: Bool) -> Bool {
    guard enabled != audioOnly else { return true }
    guard let videoUrl = currentVideoUrl, let audioUrl = currentAudioUrl else {
      return false
    }
    audioOnly = enabled
    let resumeMs = Int(CMTimeGetSeconds(player.currentTime()) * 1000)
    let wasPlaying = desiredPlaying
    pendingSeekMs = resumeMs > 0 ? resumeMs : pendingSeekMs
    desiredPlaying = wasPlaying
    ready = false
    completed = false
    failure = nil
    open(videoUrl: videoUrl, audioUrl: audioUrl)
    emit(force: true)
    return true
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
    PlaybackDiagnostics.shared.end()
    pip?.delegate = nil
    pip = nil
    pipPossibleObservation?.invalidate()
    pipPossibleObservation = nil
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
    // A failed item that only reaches a private field leaves the UI on 加载中
    // forever. It is also what the user experiences as "卡住": the surface is
    // black, the progress bar is frozen, and nothing says why.
    PlaybackDiagnostics.shared.sample([
      "stage": "failed",
      "reason": reason,
    ])
    emit(force: true)
  }

  /// Records a preparation milestone, so a session that never becomes ready can
  /// be told apart from one that becomes ready and then stalls.
  private func stage(_ name: String, _ detail: String = "") {
    PlaybackDiagnostics.shared.sample([
      "stage": name,
      "detail": detail,
    ])
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
    if let failure {
      state["error"] = failure
      // Human-readable subset: a CoreMedia domain code is not a user message.
      state["errorKind"] = failure.contains("-12927")
        ? "playlist-rejected"
        : (failure.contains("no-index") ? "no-index" : "item-failed")
    }
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
    // HDR playback eligibility is the public iOS 11+ signal and it survives
    // when the newer dynamic-range APIs are unavailable; the project's floor is
    // iOS 15, so the iOS 17-only modes are reported when present and never
    // treated as the sole answer.
    out["eligibleForHdrPlayback"] = AVPlayer.eligibleForHDRPlayback
    if #available(iOS 17.0, *) {
      out["availableHdrModes"] = AVPlayer.availableHDRModes.rawValue
    }
    out["displaySupportsHdr"] = Self.displaySupportsHdr()
    // Playback health, so a stutter can be attributed instead of guessed at.
    out["stalls"] = stallReport
    if let bridge { out["bridge"] = bridge.counterSnapshot() }
    out["declaredVideoRange"] = describedRange ?? "unspecified"
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

  /// Reads the real colour description out of the decoded track.
  ///
  /// Three answers, not two: `hdr` is true only when the transfer function is
  /// one of the extended-range ones, false when the track says SDR, and absent
  /// when the metadata is not there. The old version defaulted the missing case
  /// to false, which the UI then rendered as "confirmed SDR".
  static func describeFormats(_ track: AVAssetTrack, into out: [String: Any]) -> [String: Any] {
    var out = out
    let descriptions = (track.formatDescriptions as? [CMFormatDescription]) ?? []
    guard let format = descriptions.first else { return out }
    let codec = CMFormatDescriptionGetMediaSubType(format)
    out["codec"] = fourCC(codec)
    let dims = CMVideoFormatDescriptionGetDimensions(format)
    out["codedWidth"] = Int(dims.width)
    out["codedHeight"] = Int(dims.height)
    if let ext = CMFormatDescriptionGetExtensions(format) as? [String: Any] {
      let primaries = ext["CVImageBufferColorPrimaries"] as? String
      let transfer = ext["CVImageBufferTransferFunction"] as? String
      let matrix = ext["CVImageBufferYCbCrMatrix"] as? String
      out["primaries"] = primaries
      out["transfer"] = transfer
      out["matrix"] = matrix
      if let depth = ext["BitsPerComponent"] as? Int { out["bitDepth"] = depth }
      if let dv = ext["DolbyVisionConfiguration"] as? [String: Any] {
        out["dolbyVision"] = dv
        out["hdr"] = true
        return out
      }
      if let transfer {
        if transfer.contains("2084") {
          out["hdr"] = true
          out["transferFunction"] = "PQ"
        } else if transfer.contains("HLG") || transfer.contains("2100") {
          out["hdr"] = true
          out["transferFunction"] = "HLG"
        } else {
          // A named SDR transfer function is a positive statement.
          out["hdr"] = false
          out["transferFunction"] = "SDR"
        }
        return out
      }
    }
    // No colour metadata: leave `hdr` absent rather than claiming SDR.
    return out
  }

  /// Whether the current display can show extended range at all.
  ///
  /// Kept separate from eligibility: a device can be HDR-capable while the
  /// current screen brightness mode, an external output or a screenshot
  /// context turns it off. Cached by the system, re-read per description.
  static func displaySupportsHdr() -> Bool {
    #if canImport(UIKit)
    return UIScreen.main.traitCollection.displayGamut == .P3
    #else
    return false
    #endif
  }

  static func fourCC(_ code: FourCharCode) -> String {
    let bytes: [UInt8] = [
      UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
      UInt8((code >> 8) & 0xff), UInt8(code & 0xff),
    ]
    return String(bytes: bytes, encoding: .ascii) ?? "????"
  }
}

extension HdrVideoSession: AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerDidStartPictureInPicture(
    _ controller: AVPictureInPictureController
  ) {
    // The system now owns presentation; the session keeps decoding and its
    // intent is unchanged, but a stall-recovery must not fight it.
    interrupted = true
    HdrVideoPlugin.broadcast([
      "event": "pip",
      "sessionId": sessionId,
      "state": "started",
    ])
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ controller: AVPictureInPictureController
  ) {
    interrupted = false
    HdrVideoPlugin.broadcast([
      "event": "pip",
      "sessionId": sessionId,
      "state": "stopped",
    ])
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    HdrVideoPlugin.broadcast([
      "event": "pip",
      "sessionId": sessionId,
      "state": "failed",
      "message": error.localizedDescription,
    ])
  }

  func pictureInPictureControllerWillStartPictureInPicture(
    _ controller: AVPictureInPictureController
  ) {
    HdrVideoPlugin.broadcast([
      "event": "pip",
      "sessionId": sessionId,
      "state": "starting",
    ])
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

// MARK: - AV1 decoder capability of the loaded FFmpeg

/// Asks the FFmpeg build that this process actually loaded whether its AV1
/// decoder has a VideoToolbox path.
///
/// Why this and not a build flag: the app can ship either Avcodec (the pod's,
/// which has no AV1 VideoToolbox hwaccel, or the injected one, which does), and
/// a build that quietly kept the wrong one reported AV1 as available while every
/// frame was decoded on the CPU. The answer has to come from the loaded binary.
///
/// Why `dlsym` and no headers: there is no vendored FFmpeg header set in this
/// repository, and inventing one to match a version this app does not link would
/// be a second source of truth. The functions used here are the ABI-stable entry
/// points of libavcodec/libavutil - strings and pointers in, strings and integers
/// out - and the only struct touched is read through `avcodec_get_hw_config`,
/// whose first three fields (pixel format, methods, device type) have been the
/// same since FFmpeg 3.4.
enum Av1DecoderProbe {
  typealias FindDecoder = @convention(c) (UnsafePointer<CChar>)
    -> UnsafeMutableRawPointer?
  typealias GetHwConfig = @convention(c) (UnsafeMutableRawPointer?, Int32)
    -> UnsafeMutableRawPointer?
  typealias DeviceTypeByName = @convention(c) (UnsafePointer<CChar>) -> Int32
  typealias DeviceTypeName = @convention(c) (Int32) -> UnsafePointer<CChar>?
  typealias PixFmtByName = @convention(c) (UnsafePointer<CChar>) -> Int32
  typealias PixFmtName = @convention(c) (Int32) -> UnsafePointer<CChar>?
  typealias VersionFn = @convention(c) () -> UInt32
  typealias ConfigurationFn = @convention(c) () -> UnsafePointer<CChar>?

  /// `AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX`, from libavcodec/codec.h.
  static let methodDeviceContext: Int32 = 0x01

  private static func symbol<T>(
    _ handle: UnsafeMutableRawPointer, _ name: String, as type: T.Type
  ) -> T? {
    guard let sym = dlsym(handle, name) else { return nil }
    return unsafeBitCast(sym, to: T.self)
  }

  /// Everything the loaded FFmpeg can say about AV1, or the reason it cannot be
  /// asked.
  static func describe() -> [String: Any] {
    guard let handle = dlopen(nil, RTLD_LAZY) else {
      return ["available": false, "reason": "no image handle"]
    }
    guard
      let find = symbol(handle, "avcodec_find_decoder_by_name",
                        as: FindDecoder.self),
      let getConfig = symbol(handle, "avcodec_get_hw_config",
                             as: GetHwConfig.self),
      let deviceByName = symbol(handle, "av_hwdevice_find_type_by_name",
                                as: DeviceTypeByName.self),
      let deviceName = symbol(handle, "av_hwdevice_get_type_name",
                              as: DeviceTypeName.self),
      let pixFmtByName = symbol(handle, "av_get_pix_fmt",
                                as: PixFmtByName.self),
      let pixFmtName = symbol(handle, "av_get_pix_fmt_name",
                              as: PixFmtName.self)
    else {
      return ["available": false, "reason": "ffmpeg symbols not loaded"]
    }

    var result: [String: Any] = ["available": true]
    if let versionFn = symbol(handle, "avcodec_version", as: VersionFn.self) {
      let v = versionFn()
      result["libraryVersion"] =
        "\(v >> 16).\(((v >> 8) & 0xFF)).\((v & 0xFF))"
    }
    if let configFn = symbol(handle, "avcodec_configuration",
                             as: ConfigurationFn.self),
       let raw = configFn() {
      let configuration = String(cString: raw)
      // The configuration string of the binary that is in memory. It is a
      // build-time claim rather than a registration, so it is recorded next to
      // the hw_config enumeration instead of replacing it.
      result["configurationHasAv1VideoToolbox"] =
        configuration.contains("av1_videotoolbox")
    }

    let codec = "av1".withCString { find($0) }
    guard let codec else {
      result["decoderPresent"] = false
      result["av1VideoToolbox"] = false
      result["reason"] = "no av1 decoder in the loaded avcodec"
      return result
    }
    result["decoderPresent"] = true

    let videoToolboxType = "videotoolbox".withCString { deviceByName($0) }
    let videoToolboxPix = "videotoolbox".withCString { pixFmtByName($0) }

    var configs: [[String: Any]] = []
    var hasVideoToolbox = false
    var index: Int32 = 0
    while true {
      guard let raw = getConfig(codec, index) else { break }
      let fields = raw.assumingMemoryBound(to: Int32.self)
      let pixFmt = fields[0]
      let methods = fields[1]
      let deviceType = fields[2]
      let pixName = pixFmtName(pixFmt).map { String(cString: $0) } ?? "?"
      let devName = deviceName(deviceType).map { String(cString: $0) } ?? "none"
      configs.append([
        "pixFmt": pixName,
        "deviceType": devName,
        "methods": Int(methods),
      ])
      // Match on the device type, plus the pixel-format family by name.
      //
      // The exact enum value does not survive this comparison: libavutil answers
      // `videotoolbox` to `av_get_pix_fmt` while the hw config carries the same
      // format under its `videotoolbox_vld` alias, so an equality test reported
      // "no AV1 VideoToolbox hwaccel" for a library that plainly has one - and
      // that answer demoted AV1 on a device that decodes it in hardware.
      if deviceType == videoToolboxType && pixName.hasPrefix("videotoolbox") {
        hasVideoToolbox = true
      }
      _ = videoToolboxPix
      index += 1
    }
    result["hwConfigs"] = configs
    result["av1VideoToolbox"] = hasVideoToolbox
    if !hasVideoToolbox {
      result["reason"] =
        "the loaded avcodec registers no videotoolbox hwaccel for av1"
    }
    return result
  }
}
