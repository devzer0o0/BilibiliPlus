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
  static let maxFragments = 12

  static func assemble(
    url: URL,
    headers: [String: String],
    completion: @escaping (Result?) -> Void
  ) {
    // The front of the track: ftyp, moov and sidx all live in the first few KB.
    fetch(url: url, headers: headers, range: 0...262143) { head in
      guard let head, head.count > 0 else {
        completion(nil)
        return
      }
      guard let index = parseSidx(head) else {
        completion(nil)
        return
      }

      // Everything up to the end of the sidx is kept verbatim, so the moov and
      // the index itself survive into the output.
      let headerEnd = index.sidxEnd
      var out = head.prefix(headerEnd)

      let want = min(index.count, maxFragments)
      var offset = headerEnd  // first fragment starts right after the sidx

      var collected = 0
      var indexRef = 0

      func next() {
        if indexRef >= want {
          completion(Result(data: out, fragments: collected))
          return
        }
        let size = index.sizes[indexRef]
        let start = offset
        let end = offset + size - 1
        fetch(url: url, headers: headers, range: start...end) { body in
          guard let body, body.count > 0 else {
            // Return what we have: a shorter file still plays.
            completion(collected > 0 ? Result(data: out, fragments: collected) : nil)
            return
          }
          out.append(body)
          offset += size
          indexRef += 1
          collected += 1
          next()
        }
      }
      next()
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
    URLSession.shared.dataTask(with: request) { data, _, _ in
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

    var p = marker + 8
    guard p + 8 <= bytes.count else { return nil }
    p += 4
    p += 4
    let version = bytes[marker + 4]
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