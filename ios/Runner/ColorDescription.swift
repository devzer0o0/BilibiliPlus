import Foundation

/// Reads the colour description out of an ISO BMFF initialization segment.
///
/// The master playlist needs `VIDEO-RANGE`. Until now it was filled in from the
/// codec string, which is a guess: measured on a device, the resulting HLS
/// variant carried no VIDEO-RANGE at all, so AVFoundation treated a PQ stream as
/// ordinary SDR. The `colr` box in the sample entry is authoritative for the
/// transfer function, and it is in the init segment we already fetch.
///
/// Deliberately separate from Mp4BoxPatcher: that one rewrites bytes, this one
/// only reads. Neither scans for patterns - both walk box headers.
enum ColorDescription {
  enum Primaries: String {
    case bt709
    case bt2020
    case unknown
  }

  enum Transfer: String {
    case sdr = "SDR"
    case pq = "PQ"
    case hlg = "HLG"
    case unknown
  }

  /// `nclx` / `nclc` colour type codes from ISO/IEC 14496-12 Annex E.
  static let transferPQ = 16
  static let transferHLG = 18
  static let transferBT709 = 1
  static let transferSRGB = 13

  static let primariesBT709 = 1
  static let primariesBT2020 = 9

  struct Description: Equatable {
    let primaries: Primaries
    let transfer: Transfer
    let fullRange: Bool

    /// The `VIDEO-RANGE` attribute value, or nil when the media did not
    /// describe itself. nil stays nil: declaring SDR for an unlabelled stream
    /// is the same mistake in the other direction.
    var videoRange: String? {
      switch transfer {
      case .pq: return "PQ"
      case .hlg: return "HLG"
      case .sdr: return "SDR"
      case .unknown: return nil
      }
    }

    /// Whether this describes extended range.
    var isHdr: Bool { transfer == .pq || transfer == .hlg }
  }

  /// Walks to the visual sample entry and reads its `colr` box.
  ///
  /// Returns nil when there is no `colr` box, when the layout is not one this
  /// understands, or when the data is truncated - never a guessed value.
  static func read(_ data: Data) -> Description? {
    let bytes = [UInt8](data)
    var result: Description?
    walk(bytes, 0, bytes.count, depth: 0, into: &result)
    return result
  }

  private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]

  private static func walk(
    _ bytes: [UInt8],
    _ start: Int,
    _ end: Int,
    depth: Int,
    into result: inout Description?
  ) {
    guard depth < 8 else { return }
    var offset = start
    while offset + 8 <= end {
      let size = Int(be32(bytes, offset))
      let type = fourCC(bytes, offset + 4)
      var header = 8
      var boxSize = size
      if size == 1 {
        guard offset + 16 <= end else { return }
        let large = be64(bytes, offset + 8)
        guard large >= 16, large <= UInt64(end - offset) else { return }
        boxSize = Int(large)
        header = 16
      } else if size == 0 {
        boxSize = end - offset
      }
      guard boxSize >= header, offset + boxSize <= end else { return }
      let payload = offset + header
      let boxEnd = offset + boxSize
      if containers.contains(type) {
        walk(bytes, payload, boxEnd, depth: depth + 1, into: &result)
      } else if type == "stsd" {
        readSampleEntries(bytes, payload, boxEnd, into: &result)
      }
      offset = boxEnd
    }
  }

  private static func readSampleEntries(
    _ bytes: [UInt8],
    _ payload: Int,
    _ end: Int,
    into result: inout Description?
  ) {
    guard payload + 8 <= end else { return }
    let count = Int(be32(bytes, payload + 4))
    var offset = payload + 8
    for _ in 0..<count {
      guard offset + 8 <= end else { return }
      let size = Int(be32(bytes, offset))
      guard size >= 8, offset + size <= end else { return }
      // A visual sample entry carries a 78-byte fixed header before its child
      // boxes (reserved, data_reference_index, pre_defined, width/height,
      // resolutions, frame_count, compressorname, depth, pre_defined).
      readColr(bytes, offset + 8 + 78, offset + size, into: &result)
      offset += size
    }
  }

  private static func readColr(
    _ bytes: [UInt8],
    _ start: Int,
    _ end: Int,
    into result: inout Description?
  ) {
    var offset = start
    while offset + 8 <= end {
      let size = Int(be32(bytes, offset))
      guard size >= 8, offset + size <= end else { return }
      let type = fourCC(bytes, offset + 4)
      if type == "colr" {
        let payload = offset + 8
        let kind = fourCC(bytes, payload)
        if (kind == "nclx" || kind == "nclc") && payload + 10 <= offset + size {
          let colourPrimaries = Int(be16(bytes, payload + 4))
          let transferCode = Int(be16(bytes, payload + 6))
          var fullRange = false
          if kind == "nclx" && payload + 11 <= offset + size {
            fullRange = (bytes[payload + 10] & 0x80) != 0
          }
          result = Description(
            primaries: primaries(colourPrimaries),
            transfer: transfer(transferCode),
            fullRange: fullRange
          )
        }
        return
      }
      offset += size
    }
  }

  private static func primaries(_ code: Int) -> Primaries {
    switch code {
    case primariesBT709: return .bt709
    case primariesBT2020: return .bt2020
    default: return .unknown
    }
  }

  private static func transfer(_ code: Int) -> Transfer {
    switch code {
    case transferPQ: return .pq
    case transferHLG: return .hlg
    case transferBT709, transferSRGB, 4, 5, 6, 7, 8: return .sdr
    default: return .unknown
    }
  }

  private static func fourCC(_ bytes: [UInt8], _ at: Int) -> String {
    guard at + 4 <= bytes.count else { return "" }
    return String(bytes: bytes[at..<(at + 4)], encoding: .ascii) ?? ""
  }

  private static func be16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
    guard at + 2 <= bytes.count else { return 0 }
    return (UInt16(bytes[at]) << 8) | UInt16(bytes[at + 1])
  }

  private static func be32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
    guard at + 4 <= bytes.count else { return 0 }
    return (UInt32(bytes[at]) << 24) | (UInt32(bytes[at + 1]) << 16)
      | (UInt32(bytes[at + 2]) << 8) | UInt32(bytes[at + 3])
  }

  private static func be64(_ bytes: [UInt8], _ at: Int) -> UInt64 {
    guard at + 8 <= bytes.count else { return 0 }
    var value: UInt64 = 0
    for i in 0..<8 { value = (value << 8) | UInt64(bytes[at + i]) }
    return value
  }
}
