import Foundation

/// Structural repackaging of an ISO BMFF track for AVFoundation.
///
/// bilibili serves HDR as HEVC with an `hev1` sample entry, which
/// AVFoundation declines to play even though the bitstream is identical to
/// `hvc1`. The difference is where the parameter sets live; `hvcC` carries
/// them either way.
///
/// This walks the box tree to the `stsd` sample entry and rewrites exactly
/// that four-character code. It does not search the file for bytes: a global
/// replace also hits `mdat` payload and any string that happens to contain
/// `hev1`, which silently corrupts frames.
enum Mp4BoxPatcher {
  enum Failure: Error {
    case notAnIsoBmff
    case truncatedBox(String)
    case noSampleEntry
    case unsupportedLayout(String)
  }

  struct Report {
    let patched: Bool
    let sampleEntries: Int
    let hasHvcC: Bool
  }

  /// Rewrites `hev1` to `hvc1` in the video sample entry only.
  static func hvc1(_ data: Data) throws -> (data: Data, report: Report) {
    var bytes = [UInt8](data)
    guard bytes.count >= 8 else { throw Failure.notAnIsoBmff }

    // Top level: ftyp, moov, mdat, ...
    var found = 0
    var hasHvcC = false
    var patched = false
    var offset = 0
    while offset + 8 <= bytes.count {
      guard let box = try parseBoxHeader(bytes, at: offset, limit: bytes.count) else {
        break
      }
      if box.type == "moov" {
        let result = try walk(
          bytes: &bytes,
          from: box.payloadStart,
          to: box.end,
          depth: 0,
          state: &hasHvcC,
          patched: &patched
        )
        found += result
      }
      offset = box.end
    }
    // No HEVC sample entry is not an error: an AVC or AV1 track needs no
    // patching, and failing here would turn "nothing to do" into "cannot play".
    return (
      Data(bytes),
      Report(patched: patched, sampleEntries: found, hasHvcC: hasHvcC)
    )
  }

  struct Box {
    let type: String
    let payloadStart: Int
    let end: Int
  }

  /// Reads a box header with bounds checks, including the 64-bit form.
  static func parseBoxHeader(
    _ bytes: [UInt8],
    at offset: Int,
    limit: Int
  ) throws -> Box? {
    guard offset + 8 <= limit else {
      if offset == limit { return nil }
      throw Failure.truncatedBox("header at \(offset)")
    }
    var size = Int(be32(bytes, offset))
    let type = fourcc(bytes, offset + 4)
    var header = 8
    if size == 1 {
      guard offset + 16 <= limit else {
        throw Failure.truncatedBox("largesize at \(offset)")
      }
      let large = (UInt64(be32(bytes, offset + 8)) << 32) | UInt64(be32(bytes, offset + 12))
      guard large <= UInt64(limit - offset) else {
        throw Failure.truncatedBox("largesize \(large) at \(offset)")
      }
      size = Int(large)
      header = 16
    } else if size == 0 {
      // "to the end of the file"
      size = limit - offset
    }
    guard size >= header, offset + size <= limit else {
      throw Failure.truncatedBox("\(type) size \(size) at \(offset)")
    }
    return Box(type: type, payloadStart: offset + header, end: offset + size)
  }

  /// Container boxes inside `moov` that lead to `stsd`.
  private static let containers: Set<String> = [
    "trak", "mdia", "minf", "stbl",
  ]

  private static func walk(
    bytes: inout [UInt8],
    from start: Int,
    to end: Int,
    depth: Int,
    state: inout Bool,
    patched: inout Bool
  ) throws -> Int {
    guard depth < 8 else { throw Failure.unsupportedLayout("nesting too deep") }
    var offset = start
    var entries = 0
    while offset + 8 <= end {
      guard let box = try parseBoxHeader(bytes, at: offset, limit: end) else { break }
      if containers.contains(box.type) {
        entries += try walk(
          bytes: &bytes,
          from: box.payloadStart,
          to: box.end,
          depth: depth + 1,
          state: &state,
          patched: &patched
        )
      } else if box.type == "stsd" {
        let result = try patchSampleEntries(
          bytes: &bytes,
          boxStart: offset,
          payload: box.payloadStart,
          end: box.end,
          state: &state,
          patched: &patched
        )
        entries += result
      }
      offset = box.end
    }
    return entries
  }

  private static func patchSampleEntries(
    bytes: inout [UInt8],
    boxStart: Int,
    payload: Int,
    end: Int,
    state: inout Bool,
    patched: inout Bool
  ) throws -> Int {
    // stsd: version+flags(4) entry_count(4), then the entries.
    guard payload + 8 <= end else { throw Failure.truncatedBox("stsd") }
    let count = Int(be32(bytes, payload + 4))
    var offset = payload + 8
    var seen = 0
    for _ in 0..<count {
      guard offset + 8 <= end else { throw Failure.truncatedBox("sample entry") }
      let size = Int(be32(bytes, offset))
      guard size >= 8, offset + size <= end else {
        throw Failure.truncatedBox("sample entry size")
      }
      let type = fourcc(bytes, offset + 4)
      // Visual sample entries carry 78 bytes of fixed fields before the child
      // boxes; the coded width/height sit inside them.
      if type == "hev1" || type == "hvc1" {
        var probe = offset + 8 + 78
        let entryEnd = offset + size
        while probe + 8 <= entryEnd {
          guard let child = try parseBoxHeader(bytes, at: probe, limit: entryEnd) else {
            break
          }
          if child.type == "hvcC" { state = true }
          probe = child.end
        }
        if type == "hev1" {
          writeFourcc(&bytes, at: offset + 4, "hvc1")
          patched = true
        }
        seen += 1
      }
      offset += size
    }
    _ = boxStart
    return seen
  }

  private static func be32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
    (UInt32(bytes[at]) << 24) | (UInt32(bytes[at + 1]) << 16)
      | (UInt32(bytes[at + 2]) << 8) | UInt32(bytes[at + 3])
  }

  private static func fourcc(_ bytes: [UInt8], _ at: Int) -> String {
    String(bytes: bytes[at..<(at + 4)], encoding: .ascii) ?? ""
  }

  private static func writeFourcc(_ bytes: inout [UInt8], at: Int, _ text: String) {
    let ascii = Array(text.utf8)
    guard ascii.count == 4 else { return }
    for i in 0..<4 { bytes[at + i] = ascii[i] }
  }
}
