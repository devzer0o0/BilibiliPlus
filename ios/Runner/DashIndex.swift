import Foundation

/// The index bilibili's DASH response already provides.
///
/// The response carries `SegmentBase.Initialization` and `.indexRange`
/// (e.g. `0-999` and `1000-1259`). Those byte ranges are authoritative: the
/// old loader ignored them, guessed that everything up to the end of the
/// `sidx` was the header, and then assumed the first fragment started right
/// after it. Both assumptions are wrong on real tracks, and each wrong offset
/// shifts every later fragment.
struct DashSegmentBase: Equatable {
  /// Inclusive byte range of the initialization segment.
  let initialization: ClosedRange<Int>
  /// Inclusive byte range of the index (`sidx`).
  let indexRange: ClosedRange<Int>

  /// Parses the `"start-end"` pair the service uses.
  static func parse(_ text: String?) -> ClosedRange<Int>? {
    guard let text, !text.isEmpty else { return nil }
    let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2,
          let start = Int(parts[0]),
          let end = Int(parts[1]),
          start >= 0, end >= start
    else { return nil }
    return start...end
  }

  init?(initialization: String?, indexRange: String?) {
    guard let initRange = Self.parse(initialization) else { return nil }
    self.initialization = initRange
    // An index range is optional in the spec; without it the segment list has
    // to be discovered, and pretending otherwise produces bad offsets.
    guard let index = Self.parse(indexRange) else { return nil }
    self.indexRange = index
  }

  /// How far into the file the metadata extends.
  var headerEnd: Int { max(initialization.upperBound, indexRange.upperBound) + 1 }

  /// Where the first media fragment starts when the sidx declares no
  /// `first_offset`: immediately after the index box.
  var firstFragmentOffset: Int { indexRange.upperBound + 1 }
}

/// A parsed `sidx` with its absolute position in the file.
struct SegmentIndex {
  struct Reference {
    let referencedSize: Int
    /// The subsegment ends on a stream access point (a keyframe).
    let startsWithSap: Bool
    let subsegmentDuration: UInt32
  }

  let timescale: UInt32
  let earliestPresentationTime: UInt64
  let firstOffset: Int
  let references: [Reference]
  /// Absolute offset just past the `sidx` box.
  let boxEnd: Int

  /// Absolute byte offset of a reference in the *track*, in order.
  ///
  /// [boxEnd] is where the box ends inside the buffer that was parsed. When the
  /// index is fetched as its own ranged read the buffer starts mid-file, so the
  /// absolute position is `sliceStart + boxEnd`. Getting this wrong puts the
  /// first fragment at byte 260 instead of 1260 and every later one behind it.
  func offset(of index: Int, sliceStart: Int = 0) -> Int {
    var offset = sliceStart + boxEnd + firstOffset
    for i in 0..<index {
      offset += references[i].referencedSize
    }
    return offset
  }

  var totalSize: Int { references.reduce(0) { $0 + $1.referencedSize } }
}

enum SidxParser {
  enum Failure: Error {
    case tooShort
    case badBox
    case unsupportedVersion(UInt8)
  }

  /// Parses the box that starts at [boxStart] inside [data].
  ///
  /// Sizes and offsets are read with bounds checks; a truncated or hostile
  /// index is rejected instead of being reinterpreted as media bytes.
  static func parse(_ data: Data, boxStart: Int = 0) throws -> SegmentIndex {
    let bytes = [UInt8](data)
    let base = boxStart
    guard base >= 0, base + 12 <= bytes.count else { throw Failure.tooShort }

    let size = Int(be32(bytes, base))
    let type = String(bytes: bytes[(base + 4)..<(base + 8)], encoding: .ascii) ?? ""
    guard type == "sidx" else { throw Failure.badBox }
    guard size >= 12, base + size <= bytes.count else { throw Failure.tooShort }

    let version = bytes[base + 8]
    guard version == 0 || version == 1 else {
      throw Failure.unsupportedVersion(version)
    }

    var p = base + 12            // version+flags
    p += 4                       // reference_id
    let timescale = be32(bytes, p)
    p += 4
    var earliest: UInt64 = 0
    if version == 0 {
      earliest = UInt64(be32(bytes, p))
      p += 4
    } else {
      earliest = (UInt64(be32(bytes, p)) << 32) | UInt64(be32(bytes, p + 4))
      p += 8
    }
    guard p + 4 <= base + size else { throw Failure.tooShort }
    var firstOffset = 0
    if version == 0 {
      firstOffset = Int(be32(bytes, p) & 0x7FFF_FFFF)
      p += 4
    } else {
      firstOffset = Int((UInt64(be32(bytes, p)) << 32) | UInt64(be32(bytes, p + 4)))
      p += 8
    }
    guard p + 4 <= base + size else { throw Failure.tooShort }
    p += 2                       // reserved
    let count = Int(be16(bytes, p))
    p += 2

    var references: [SegmentIndex.Reference] = []
    references.reserveCapacity(count)
    for _ in 0..<count {
      guard p + 12 <= base + size else { throw Failure.tooShort }
      // Layout per ISO/IEC 14496-12:
      //   reference_type(1) | referenced_size(31)
      //   subsegment_duration(32)
      //   starts_with_SAP(1) | SAP_type(3) | SAP_delta_time(28)
      // Reading size off the third word (the SAP word) is a mistake that only
      // shows up against a real track: the sizes look plausible, the offsets
      // do not, and every fragment lands in the wrong place.
      let sizeWord = be32(bytes, p)
      let duration = be32(bytes, p + 4)
      let sapWord = be32(bytes, p + 8)
      let referencedSize = Int(sizeWord & 0x7FFF_FFFF)
      let sap = (sapWord & 0x8000_0000) != 0
      guard referencedSize > 0 else { throw Failure.badBox }
      references.append(
        SegmentIndex.Reference(
          referencedSize: referencedSize,
          startsWithSap: sap,
          subsegmentDuration: duration
        )
      )
      p += 12
    }
    return SegmentIndex(
      timescale: timescale,
      earliestPresentationTime: earliest,
      firstOffset: firstOffset,
      references: references,
      boxEnd: base + size
    )
  }

  private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
    (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16) | (UInt32(b[i + 2]) << 8)
      | UInt32(b[i + 3])
  }

  private static func be16(_ b: [UInt8], _ i: Int) -> UInt16 {
    (UInt16(b[i]) << 8) | UInt16(b[i + 1])
  }
}
