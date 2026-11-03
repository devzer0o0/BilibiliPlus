import Foundation

/// Builds a playable file out of a bilibili DASH track.
///
/// The URL points at the whole track but only supports ranged reads; the front
/// of it holds `ftyp`/`moov`/`sidx`, and after that comes one `moof`+`mdat` pair
/// per fragment. Fetching a fixed prefix gives about a second of 4K, which plays
/// but is useless. This walks the `sidx` and pulls the fragments it names.
enum DashAssembler {
  struct Result {
    let data: Data
    let fragments: Int
  }

  /// How many fragments to fetch. Each is five seconds here, so this is roughly
  /// a minute - enough to watch without pulling a whole 40 MB track.
  static let maxFragments = 19

  /// Last parsed index summary, surfaced through the controller for diagnosis.
  nonisolated(unsafe) static var debugNote = ""

  static func assemble(
    url: URL,
    headers: [String: String],
    onFragment: ((Int, Int) -> Void)? = nil,
    completion: @escaping (Result?) -> Void
  ) {
    // The front of the track: ftyp, moov and sidx all live in the first few KB.
    fetch(url: url, headers: headers, range: 0...262143) { head in
      guard let head, head.count > 0 else {
        completion(nil)
        return
      }
      guard let index = parseSidx(head) else {
        // Report why: a missing sidx and a malformed one look identical from
        // the caller, which then falls back to the raw URL and plays nothing.
        debugNote =
          "no-sidx len=\(head.count) "
          + "hasSidx=\(head.range(of: Data("sidx".utf8)) != nil)"
        completion(nil)
        return
      }

      // Everything up to the end of the sidx is kept verbatim, so the moov and
      // the index itself survive into the output.
      let headerEnd = index.sidxEnd
      var out = head.prefix(headerEnd)

      let want = min(index.count, maxFragments)
      var offset = headerEnd  // first fragment starts right after the sidx
      debugNote = "count=\(index.count) headEnd=\(headerEnd) "
        + "headLen=\(head.count)"

      var collected = 0
      var indexRef = 0

      // A fragment that arrives short or not at all must not be dropped: the
      // offset advances by the size the sidx declared, so skipping one puts
      // every fragment after it in the wrong place. Retry the same range, and
      // only give up on the whole track once it keeps failing.
      let attempts = 3

      func fetchFragment(_ attempt: Int) {
        if indexRef >= want {
          completion(Result(data: out, fragments: collected))
          return
        }
        let size = index.sizes[indexRef]
        let start = offset
        let end = offset + size - 1
        let ref = indexRef
        fetch(url: url, headers: headers, range: start...end) { body in
          if let body, body.count == size {
            out.append(body)
            offset += size
            indexRef += 1
            collected += 1
            onFragment?(collected, want)
            fetchFragment(0)
            return
          }
          if attempt + 1 < attempts {
            fetchFragment(attempt + 1)
            return
          }
          // Out of retries. Keep what has already been assembled rather than
          // discarding it - a shorter file still plays, an empty one does not.
          debugNote += " | frag\(ref) want=\(size) got=\(body?.count ?? -1)"
            + " after \(attempts)"
          completion(collected > 0 ? Result(data: out, fragments: collected) : nil)
        }
      }
      fetchFragment(0)
    }
  }

  private static func fetch(
    url: URL,
    headers: [String: String],
    range: ClosedRange<Int>,
    completion: @escaping (Data?) -> Void
  ) {
    var request = URLRequest(url: url)
    for (k, v) in headers {
      request.setValue(v, forHTTPHeaderField: k)
    }
    request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)",
                     forHTTPHeaderField: "Range")
    // Fragments are several megabytes; the default timeout gives up mid-body
    // on a slow link and the short body then desynchronises every offset after
    // it. Wait for the whole range instead.
    request.timeoutInterval = 60
    URLSession.shared.dataTask(with: request) { data, response, error in
      // Surface transport failures: a timeout or a refused connection otherwise
      // looks exactly like "the server sent nothing", and the caller silently
      // falls back to the raw URL and plays an empty item.
      if let error {
        debugNote += " | err@\(range.lowerBound)=\(error.localizedDescription)"
        completion(nil)
        return
      }
      if let http = response as? HTTPURLResponse, http.statusCode != 206 {
        debugNote += " | http@\(range.lowerBound)=\(http.statusCode)"
      }
      completion(data)
    }.resume()
  }

  struct Index {
    let count: Int
    let sizes: [Int]
    let sidxEnd: Int
  }

  /// Minimal sidx reader: enough to know each fragment's byte length.
  ///
  /// Works on a byte array - Data indices are not zero-based after slicing,
  /// which silently breaks offset arithmetic.
  static func parseSidx(_ data: Data) -> Index? {
    let bytes = [UInt8](data)
    guard bytes.count > 16 else { return nil }

    var marker = -1
    var i = 0
    while i + 8 <= bytes.count {
      if bytes[i + 4] == 0x73, bytes[i + 5] == 0x69,
         bytes[i + 6] == 0x64, bytes[i + 7] == 0x78 {
        marker = i
        break
      }
      i += 1
    }
    guard marker >= 0 else { return nil }

    func be32(_ at: Int) -> Int {
      (Int(bytes[at]) << 24) | (Int(bytes[at + 1]) << 16) |
        (Int(bytes[at + 2]) << 8) | Int(bytes[at + 3])
    }
    func be16(_ at: Int) -> Int {
      (Int(bytes[at]) << 8) | Int(bytes[at + 1])
    }

    let boxSize = be32(marker)
    let sidxEnd = marker + boxSize
    guard boxSize > 0, sidxEnd <= bytes.count else { return nil }

    // marker is the box start:
    //   [size:4][type:4][version+flags:4][refID:4][timescale:4]
    //   [earliest_pto][first_offset][reserved:2][count:2]
    // Reading version at marker+4 landed on the type field, which made every
    // offset after it wrong and produced a fragment count in the thousands.
    let version = bytes[marker + 8]
    var p = marker + 20
    p += (version == 0) ? 8 : 16
    guard p + 2 <= bytes.count else { return nil }
    p += 2
    let count = be16(p)
    p += 2

    var sizes: [Int] = []
    sizes.reserveCapacity(count)
    for _ in 0..<count {
      guard p + 12 <= bytes.count else { break }
      sizes.append(be32(p) & 0x7FFF_FFFF)
      p += 12
    }
    return Index(count: sizes.count, sizes: sizes, sidxEnd: sidxEnd)
  }
}