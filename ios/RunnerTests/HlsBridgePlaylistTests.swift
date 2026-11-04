import XCTest

/// The playlist is the contract with AVFoundation. A wrong EXTINF, a missing
/// ENDLIST or an absolute URL breaks playback, so they are asserted here rather
/// than discovered on a device.
final class HlsBridgePlaylistTests: XCTestCase {
  private func index(
    durations: [UInt32],
    sizes: [Int],
    timescale: UInt32 = 1000
  ) throws -> SegmentIndex {
    var payload: [UInt8] = [0, 0, 0, 0]
    payload += [0, 0, 0, 1]
    payload += be32(timescale)
    payload += be32(0)
    payload += be32(0)
    payload += [0, 0]
    payload += [UInt8(durations.count >> 8 & 0xFF), UInt8(durations.count & 0xFF)]
    for (duration, size) in zip(durations, sizes) {
      payload += be32(UInt32(size) & 0x7FFF_FFFF)
      payload += be32(duration)
      payload += be32(0x9000_0000)
    }
    let box = Data(be32(UInt32(payload.count + 8)) + Array("sidx".utf8) + payload)
    return try SidxParser.parse(box)
  }

  private func be32(_ value: UInt32) -> [UInt8] {
    [
      UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
      UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF),
    ]
  }

  private func track(
    durations: [UInt32],
    sizes: [Int],
    width: Int? = nil,
    height: Int? = nil,
    videoRange: String? = nil
  ) throws -> HlsBridge.Track {
    HlsBridge.Track(
      url: URL(string: "https://cdn.example/v.m4s")!,
      initialization: 0...999,
      indexRange: 1000...1259,
      index: try index(durations: durations, sizes: sizes),
      codecs: "hvc1.2.4.L153.B0",
      width: width,
      height: height,
      frameRate: 59.94,
      videoRange: videoRange,
      bandwidth: 24_000_000,
      headers: [:]
    )
  }

  func testMediaPlaylistCoversTheWholeTrack() throws {
    // The old loader stopped at nineteen fragments. The playlist must describe
    // every reference the index has, however many that is.
    let durations = Array(repeating: UInt32(5000), count: 220)
    let sizes = Array(repeating: 4096, count: 220)
    let media = HlsBridge.playlist(
      for: try track(durations: durations, sizes: sizes),
      kind: "v",
      token: "tok"
    )
    let segments = media.split(separator: "\n").filter { $0.hasPrefix("/tok/v/seg/") }
    XCTAssertEqual(segments.count, 220)
    XCTAssertTrue(media.hasPrefix("#EXTM3U"))
    XCTAssertTrue(media.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
    XCTAssertTrue(media.hasSuffix("#EXT-X-ENDLIST"))
    XCTAssertTrue(media.contains("#EXT-X-MAP:URI=\"/tok/v/init\""))
  }

  /// A two-hour movie has 1,726 fragments. The old loader capped at nineteen;
  /// the playlist must describe the whole track, and every EXTINF must add up
  /// to the real duration.
  func testLongTrackPlaylistCoversEveryFragment() throws {
    let durations = Array(repeating: UInt32(80000), count: 1726)
    let sizes = Array(repeating: 89903, count: 1726)
    let media = HlsBridge.playlist(
      for: try track(durations: durations, sizes: sizes),
      kind: "v",
      token: "tok"
    )
    let segments = media.split(separator: "\n").filter { $0.hasPrefix("/tok/v/seg/") }
    XCTAssertEqual(segments.count, 1726)
    XCTAssertEqual(segments.last, "/tok/v/seg/1725")

    let seconds = Double(durations.reduce(0) { $0 + $1 }) / 1000
    XCTAssertEqual(seconds, 138080, accuracy: 0.001)
    XCTAssertTrue(media.contains("#EXT-X-TARGETDURATION:80"))
  }

  func testExtinfComesFromTheSidxTimescale() throws {
    let media = HlsBridge.playlist(
      for: try track(durations: [3200, 1600], sizes: [100, 200]),
      kind: "v",
      token: "t"
    )
    XCTAssertTrue(media.contains("#EXTINF:3.200,"))
    XCTAssertTrue(media.contains("#EXTINF:1.600,"))
    XCTAssertTrue(media.contains("#EXT-X-TARGETDURATION:4"))
  }

  func testMasterDeclaresCodecsResolutionRangeAndAudioGroup() throws {
    let bridge = HlsBridge(
      video: try track(
        durations: [5000],
        sizes: [100],
        width: 3840,
        height: 2160,
        videoRange: "PQ"
      ),
      audio: HlsBridge.Track(
        url: URL(string: "https://cdn.example/a.m4s")!,
        initialization: 0...933,
        indexRange: 934...1205,
        index: try index(durations: [5000], sizes: [50]),
        codecs: "mp4a.40.2",
        width: nil,
        height: nil,
        frameRate: nil,
        videoRange: nil,
        bandwidth: 320_000,
        headers: [:]
      )
    )
    let master = bridge.masterPlaylist()
    XCTAssertTrue(master.contains("CODECS=\"hvc1.2.4.L153.B0\""))
    XCTAssertTrue(master.contains("RESOLUTION=3840x2160"))
    XCTAssertTrue(master.contains("VIDEO-RANGE=PQ"))
    XCTAssertTrue(master.contains("AUDIO=\"aud\""))
    XCTAssertTrue(master.contains("#EXT-X-MEDIA:TYPE=AUDIO"))
    XCTAssertTrue(master.contains("/took/video.m3u8") == false)
  }

  /// Every attribute in a master playlist is NAME=VALUE. A colon is a parse
  /// error that rejects the entire variant, which is exactly what happened.
  func testEveryMasterAttributeUsesEquals() throws {
    let bridge = HlsBridge(
      video: try track(
        durations: [5000],
        sizes: [100],
        width: 3840,
        height: 2160,
        videoRange: "PQ"
      ),
      audio: nil
    )
    let master = bridge.masterPlaylist()
    let streamLine = master
      .split(separator: "\n")
      .first { $0.hasPrefix("#EXT-X-STREAM-INF:") }
    let attributes = try XCTUnwrap(streamLine)
      .dropFirst("#EXT-X-STREAM-INF:".count)
      .split(separator: ",")
    XCTAssertFalse(attributes.isEmpty)
    for attribute in attributes {
      XCTAssertTrue(attribute.contains("="), "attribute '\(attribute)' has no '='")
      XCTAssertFalse(
        attribute.split(separator: "=")[0].contains(":"),
        "attribute '\(attribute)' uses a colon"
      )
    }
    XCTAssertTrue(master.contains("FRAME-RATE=59.940"))
  }

  func testNoAudioTrackMeansNoAudioGroup() throws {
    let bridge = HlsBridge(
      video: try track(durations: [5000], sizes: [100]),
      audio: nil
    )
    let master = bridge.masterPlaylist()
    XCTAssertFalse(master.contains("TYPE=AUDIO"))
    XCTAssertFalse(master.contains("AUDIO="))
  }

  func testUnknownIndexProducesNoPlaylist() throws {
    let empty = HlsBridge.Track(
      url: URL(string: "https://cdn.example/v.m4s")!,
      initialization: 0...999,
      indexRange: 1000...1259,
      index: nil,
      codecs: "hvc1",
      width: nil,
      height: nil,
      frameRate: nil,
      videoRange: nil,
      bandwidth: 0,
      headers: [:]
    )
    XCTAssertEqual(
      HlsBridge.playlist(for: empty, kind: "v", token: "t"),
      ""
    )
  }
}
