import Foundation
import Network

/// Turns bilibili's fragmented DASH tracks into an HLS presentation that
/// AVFoundation can play as **one** `AVPlayerItem`.
///
/// Why a bridge rather than two players: two `AVPlayer`s each run their own
/// clock, so a seek, a stall or a rate change on one of them desynchronises
/// audio from picture and needs a timer to chase it. One item with an
/// `EXT-X-MEDIA` audio group shares the system clock instead.
///
/// Only playlists and byte ranges are served here. Segment bytes are streamed
/// from upstream on demand, so opening a two-hour track does not download it.
final class HlsBridge {
  enum Failure: Error {
    case badUpstream(String)
    case listenerFailed(String)
  }

  struct Track {
    let url: URL
    /// `SegmentBase.Initialization`, the `ftyp`+`moov` range.
    let initialization: ClosedRange<Int>
    /// The `sidx` range. The first media fragment starts right after it,
    /// unless the index declares a `first_offset`.
    let indexRange: ClosedRange<Int>
    /// Parsed from the `sidx` once it has been fetched.
    var index: SegmentIndex?
    /// mime + codecs, as they must appear in the master playlist.
    let codecs: String
    let width: Int?
    let height: Int?
    let frameRate: Double?
    let videoRange: String?
    let bandwidth: Int
    /// Headers the upstream CDN requires. Only ever sent to the track's own
    /// origin, never exposed to the client.
    let headers: [String: String]
  }

  let video: Track
  let audio: Track?
  /// Unguessable path prefix; the listener refuses anything else.
  let token: String
  private(set) var port: UInt16 = 0

  private var listener: NWListener?
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private let queue = DispatchQueue(label: "pilipilus.hlsbridge")

  init(video: Track, audio: Track?, token: String = UUID().uuidString) {
    self.video = video
    self.audio = audio
    self.token = token.replacingOccurrences(of: "-", with: "")
  }

  // MARK: - Playlists (pure, unit-testable)

  /// `#EXTINF` values come from the `sidx`, so a playlist describes the whole
  /// track and not a fixed number of fragments.
  static func playlist(for track: Track, kind: String, token: String) -> String {
    guard let index = track.index else { return "" }
    let target = targetDuration(index)
    var lines = [
      "#EXTM3U",
      "#EXT-X-VERSION:7",
      "#EXT-X-PLAYLIST-TYPE:VOD",
      "#EXT-X-TARGETDURATION:\(target)",
      "#EXT-X-MEDIA-SEQUENCE:0",
      "#EXT-X-INDEPENDENT-SEGMENTS",
      "#EXT-X-MAP:URI=\"/\(token)/\(kind)/init\"",
    ]
    for (i, reference) in index.references.enumerated() {
      let seconds = Double(reference.subsegmentDuration) / Double(max(index.timescale, 1))
      lines.append(String(format: "#EXTINF:%.3f,", seconds))
      lines.append("/\(token)/\(kind)/seg/\(i)")
    }
    lines.append("#EXT-X-ENDLIST")
    return lines.joined(separator: "\n")
  }

  static func targetDuration(_ index: SegmentIndex) -> Int {
    let longest = index.references
      .map { Double($0.subsegmentDuration) / Double(max(index.timescale, 1)) }
      .max() ?? 1
    return max(1, Int(longest.rounded(.up)))
  }

  /// Master playlist: one video variant plus the audio group, when there is a
  /// separate audio track.
  func masterPlaylist() -> String {
    guard video.index != nil else { return "" }
    var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
    if audio != nil {
      lines.append(
        "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"main\","
          + "DEFAULT=YES,AUTOSELECT=YES,URI=\"/\(token)/audio.m3u8\""
      )
    }
    var attributes = [
      "BANDWIDTH=\(max(video.bandwidth, 1))",
      "CODECS=\"\(video.codecs)\"",
    ]
    if let width = video.width, let height = video.height, width > 0, height > 0 {
      attributes.append("RESOLUTION=\(width)x\(height)")
    }
    if let rate = video.frameRate, rate > 0 {
      // Attribute syntax is NAME=VALUE. A colon here is a playlist parse
      // error, and the parser rejects the whole variant, not just the field.
      attributes.append(String(format: "FRAME-RATE=%.3f", rate))
    }
    if let range = video.videoRange, !range.isEmpty {
      attributes.append("VIDEO-RANGE=\(range)")
    }
    lines.append(
      "#EXT-X-STREAM-INF:\(attributes.joined(separator: ","))"
        + (audio != nil ? ",AUDIO=\"aud\"" : "")
    )
    lines.append("/\(token)/video.m3u8")
    return lines.joined(separator: "\n")
  }

  // MARK: - Serving

  func start() throws -> UInt16 {
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    // Loopback only: this must never be reachable from the LAN or by AirPlay
    // receivers elsewhere on the network.
    parameters.requiredInterfaceType = .loopback
    let listener = try NWListener(using: parameters, on: .any)
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in
      if case .ready = state { ready.signal() }
      if case let .failed(error) = state {
        assertionFailure("HLS bridge listener failed: \(error)")
        ready.signal()
      }
    }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 5) == .success,
          let port = listener.port?.rawValue
    else {
      listener.cancel()
      throw Failure.listenerFailed("no port")
    }
    self.listener = listener
    self.port = port
    return port
  }

  func stop() {
    listener?.cancel()
    listener = nil
    for connection in connections.values { connection.cancel() }
    connections.removeAll()
  }

  private func accept(_ connection: NWConnection) {
    let key = ObjectIdentifier(connection)
    connections[key] = connection
    connection.stateUpdateHandler = { [weak self] state in
      if case .cancelled = state { self?.connections.removeValue(forKey: key) }
      if case .failed = state { self?.connections.removeValue(forKey: key) }
    }
    connection.start(queue: queue)
    readRequest(connection, buffer: Data())
  }

  private func readRequest(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
      [weak self] chunk, _, isComplete, error in
      guard let self else { return }
      var data = buffer
      if let chunk { data.append(chunk) }
      if let range = data.range(of: Data("\r\n\r\n".utf8)) {
        let head = String(decoding: data[..<range.lowerBound], as: UTF8.self)
        self.respond(to: head, on: connection)
        return
      }
      if error != nil || isComplete || data.count > 64 * 1024 {
        connection.cancel()
        return
      }
      self.readRequest(connection, buffer: data)
    }
  }

  private func respond(to head: String, on connection: NWConnection) {
    let firstLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
    let parts = firstLine.split(separator: " ")
    // HLS clients issue both GET and HEAD. Refusing HEAD made AVFoundation
    // treat the resource as missing on the second probe, which is one of the
    // ways the item failed to become ready.
    guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
      send(status: "405 Method Not Allowed", body: Data(), on: connection)
      return
    }
    let isHead = parts[0] == "HEAD"
    let path = String(parts[1]).split(separator: "?").first.map(String.init) ?? String(parts[1])
    guard path.hasPrefix("/\(token)/") else {
      // Anything not under the token is refused, so the bridge cannot be used
      // as a general proxy.
      send(status: "404 Not Found", body: Data(), on: connection)
      return
    }
    let rest = String(path.dropFirst(token.count + 2))
    HlsBridge.trace("GET \(rest)")

    if rest == "master.m3u8" {
      sendM3U8(masterPlaylist(), on: connection)
    } else if rest == "video.m3u8" {
      sendM3U8(Self.playlist(for: video, kind: "v", token: token), on: connection)
    } else if rest == "audio.m3u8", let audio {
      sendM3U8(Self.playlist(for: audio, kind: "a", token: token), on: connection)
    } else if rest == "v/init" {
      // The init segment is where the HEVC sample entry lives. `hev1` is
      // refused by AVFoundation even though the bitstream is identical to
      // `hvc1`; the structural patch runs here, on the metadata only.
      stream(track: video, range: video.initialization, patch: .hvc1, on: connection)
    } else if rest == "a/init", let audio {
      stream(track: audio, range: audio.initialization, on: connection)
    } else if rest.hasPrefix("v/seg/"), let n = Int(rest.dropFirst(6)) {
      streamSegment(track: video, index: n, on: connection)
    } else if rest.hasPrefix("a/seg/"), let n = Int(rest.dropFirst(6)), let audio {
      streamSegment(track: audio, index: n, on: connection)
    } else {
      send(status: "404 Not Found", body: Data(), on: connection)
    }
    _ = isHead
  }

  /// Bounded request trace.
  ///
  /// A device gives no usable console while playback is being judged, and a
  /// silent failure is indistinguishable from a hung player. Only method and
  /// route are recorded - never URLs, headers or credentials - and only when
  /// `PILIPLUS_HLS_TRACE` is set in the scheme.
  static func trace(_ line: String) {
    guard ProcessInfo.processInfo.environment["PILIPLUS_HLS_TRACE"] == "1" else {
      return
    }
    NSLog("[hls] %@", line)
  }

  private func sendM3U8(_ text: String, on connection: NWConnection) {
    let body = Data(text.utf8)
    send(
      status: "200 OK",
      headers: [
        "Content-Type": "application/vnd.apple.mpegurl",
        "Content-Length": "\(body.count)",
        "Cache-Control": "no-store",
      ],
      body: body,
      on: connection
    )
  }

  private func streamSegment(track: Track, index: Int, on connection: NWConnection) {
    guard let segments = track.index,
          index >= 0, index < segments.references.count
    else {
      send(status: "404 Not Found", body: Data(), on: connection)
      return
    }
    let size = segments.references[index].referencedSize
    // The index was fetched as its own ranged read, so its offsets are relative
    // to that slice. Serving `offset(of:)` unadjusted would request bytes from
    // the file header instead of the fragment.
    let start = segments.offset(of: index, sliceStart: track.indexRange.lowerBound)
    stream(track: track, range: start...(start + size - 1), on: connection)
  }

  /// What to do to the bytes before serving them.
  enum Patch {
    case none
    /// Rewrite a `hev1` sample entry to `hvc1` inside `stsd`.
    case hvc1
  }

  /// Proxies one byte range upstream and answers with `206` semantics.
  ///
  /// The upstream request is a plain ranged GET: the CDN already serves these
  /// tracks as ranged reads, so nothing has to be buffered or re-encoded.
  private func stream(
    track: Track,
    range: ClosedRange<Int>,
    patch: Patch = .none,
    on connection: NWConnection
  ) {
    var request = URLRequest(url: track.url)
    request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
    for (key, value) in track.headers {
      request.setValue(value, forHTTPHeaderField: key)
    }
    request.timeoutInterval = 60
    let expected = range.upperBound - range.lowerBound + 1
    URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      if let http = response as? HTTPURLResponse, http.statusCode != 206 {
        // A 200 means the server ignored Range and sent the whole track.
        // Appending it as if it were this fragment would corrupt every offset
        // after it, so this is reported rather than papered over.
        HlsBridge.trace("upstream \(http.statusCode) for \(range)")
        self.send(
          status: "502 Bad Gateway",
          headers: ["X-Bridge-Error": "upstream-status-\(http.statusCode)"],
          body: Data(),
          on: connection
        )
        return
      }
      guard var data, data.count == expected else {
        _ = error
        self.send(status: "502 Bad Gateway", body: Data(), on: connection)
        return
      }
      if case .hvc1 = patch {
        // Structural, not a byte scan: only the sample entry's fourcc changes,
        // and `mdat` bytes are left untouched.
        if let patched = try? Mp4BoxPatcher.hvc1(data), patched.report.patched {
          data = patched.data
        }
      }
      // The playlist names this resource in full, so the response is the whole
      // resource. A `206` with a wildcard total makes AVFoundation treat the
      // fragment as a partial resource it cannot size, and the item fails
      // before the first frame.
      self.send(
        status: "200 OK",
        headers: [
          "Content-Type": "video/mp4",
          "Content-Length": "\(data.count)",
        ],
        body: data,
        on: connection
      )
    }.resume()
  }

  private func send(
    status: String,
    headers: [String: String] = [:],
    body: Data,
    on connection: NWConnection
  ) {
    var head = "HTTP/1.1 \(status)\r\n"
    var all = headers
    all["Connection"] = "close"
    all["Accept-Ranges"] = "bytes"
    if all["Content-Length"] == nil { all["Content-Length"] = "\(body.count)" }
    for (key, value) in all {
      head += "\(key): \(value)\r\n"
    }
    head += "\r\n"
    var payload = Data(head.utf8)
    payload.append(body)
    connection.send(
      content: payload,
      completion: .contentProcessed { _ in connection.cancel() }
    )
  }
}
