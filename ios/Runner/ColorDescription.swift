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

  /// The Dolby Vision configuration record (`dvcC` / `dvvC`).
  ///
  /// This is the only honest answer to "which profile is this", and the profile
  /// is what decides whether the picture can be presented at all:
  ///
  /// - profile 5 has no HDR10 or HLG base layer. Its samples are IPT-PQ-c2, and
  ///   the matrices needed to undo that live in the RPU, not in the bitstream
  ///   header. Decoding it as ordinary HEVC therefore shifts every colour, which
  ///   is the green/purple cast people see.
  /// - profiles 7/8 carry a base layer a normal renderer can show, so they
  ///   degrade gracefully to HDR10/HLG.
  ///
  /// Reading the box is not optional: the codec string alone cannot distinguish
  /// them, since both are ten-bit HEVC.
  struct DolbyVisionConfig: Equatable {
    let versionMajor: Int
    let versionMinor: Int
    /// 4 = dvhe, 5 = dvh1, 6 = dvav, 7 = dva1, 8 = dvhe, 9 = dvh1.
    let profile: Int
    let level: Int
    let rpuPresent: Bool
    let elPresent: Bool
    let blPresent: Bool

    /// Whether an ordinary renderer can show a usable picture.
    ///
    /// Profile 5 is the one that cannot: with no compatible base layer, a
    /// renderer that ignores the RPU is not "slightly off", it is wrong for the
    /// whole frame. Profiles 7 and 8 fall back to their HDR10/HLG base.
    var hasCompatibleBaseLayer: Bool { profile != 5 }

    /// Profile 5 as described by Dolby; kept as a name for logs and UI.
    var isProfile5: Bool { profile == 5 }
  }

  struct Description: Equatable {
    let primaries: Primaries
    let transfer: Transfer
    let fullRange: Bool
    /// Present only when the sample entry carried a Dolby Vision record.
    var dolbyVision: DolbyVisionConfig?

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
    var dv: DolbyVisionConfig?
    walk(bytes, 0, bytes.count, depth: 0, into: &result, dv: &dv)
    // The two records are independent: `dvcC` may sit before `colr`, and a
    // stream can carry one without the other. Merge at the end instead of
    // requiring a fixed order inside the sample entry.
    if var described = result {
      described.dolbyVision = dv
      return described
    }
    return nil
  }

  private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]

  private static func walk(
    _ bytes: [UInt8],
    _ start: Int,
    _ end: Int,
    depth: Int,
    into result: inout Description?,
    dv: inout DolbyVisionConfig?
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
        walk(bytes, payload, boxEnd, depth: depth + 1, into: &result, dv: &dv)
      } else if type == "stsd" {
        readSampleEntries(bytes, payload, boxEnd, into: &result, dv: &dv)
      }
      offset = boxEnd
    }
  }

  private static func readSampleEntries(
    _ bytes: [UInt8],
    _ payload: Int,
    _ end: Int,
    into result: inout Description?,
    dv: inout DolbyVisionConfig?
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
      let entryChildren = offset + 8 + 78
      let entryEnd = offset + size
      readColr(bytes, entryChildren, entryEnd, into: &result)
      readDolbyVision(bytes, entryChildren, entryEnd, into: &dv)
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

  /// Reads `dvcC` / `dvvC` from a visual sample entry.
  ///
  /// Layout (all big-endian, after the 8-byte box header):
  ///
  ///   0..1   dv_version_major
  ///   2..3   dv_version_minor
  ///   byte 4, bits 7..1 = dv_profile, bit 0 = dv_level high bit
  ///   byte 5, bits 7..2 = dv_level low bits, bit 1 = rpu, bit 0 = el
  ///   byte 6, bit 7     = bl_present
  ///
  /// The first byte packs profile into 7 bits, which is why a naive read of a
  /// whole byte yields a plausible but wrong number.
  private static func readDolbyVision(
    _ bytes: [UInt8],
    _ start: Int,
    _ end: Int,
    into dv: inout DolbyVisionConfig?
  ) {
    var offset = start
    while offset + 8 <= end {
      let size = Int(be32(bytes, offset))
      guard size >= 8, offset + size <= end else { return }
      let type = fourCC(bytes, offset + 4)
      if type == "dvcC" || type == "dvvC" {
        let payload = offset + 8
        // Need the version, the packed profile/level pair and the flag byte.
        guard payload + 7 <= offset + size else { return }
        let major = Int(be16(bytes, payload))
        let minor = Int(be16(bytes, payload + 2))
        let profileByte = Int(bytes[payload + 4])
        let levelByte = Int(bytes[payload + 5])
        let flagByte = Int(bytes[payload + 6])
        let profile = profileByte >> 1
        let level = ((profileByte & 0x01) << 5) | (levelByte >> 3)
        let rpu = (levelByte & 0x04) != 0
        let el = (levelByte & 0x02) != 0
        let bl = (flagByte & 0x80) != 0
        // A DV record with no `colr` box still says which profile this is,
        // even though it does not describe a transfer function. Record it and
        // leave the colour description unset rather than inventing one.
        dv = DolbyVisionConfig(
          versionMajor: major,
          versionMinor: minor,
          profile: profile,
          level: level,
          rpuPresent: rpu,
          elPresent: el,
          blPresent: bl
        )
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
// MARK: - Dynamic range when nothing else says

extension ColorDescription {
  /// The catalogue rungs that are HDR.
  ///
  /// The only dependable statement about dynamic range for a rendition whose
  /// init segment has no `colr` box: Bilibili serves HDR on these quality ids
  /// and nowhere else.
  static let hdrQualities: Set<Int> = [125, 126, 129]

  /// The `VIDEO-RANGE` to declare when neither the media nor the caller said.
  ///
  /// Bit depth is not a transfer function. This used to answer PQ for *any*
  /// ten-bit HEVC or AV1 track whose range was unknown, which is right for an
  /// HDR10 rung and wrong for the ten-bit SDR streams the catalogue also ships -
  /// and "wrong" here means AVFoundation tone-maps an SDR picture as if it were
  /// HDR, which looks like a decoder fault rather than a metadata fault.
  ///
  /// `nil` means "not known". The playlist then declares no range and the
  /// format description decides from the bitstream, which is the honest default.
  static func rangeWhenUnknown(codecs: String?, quality: Int?) -> String? {
    guard let codecs, !codecs.isEmpty else { return nil }

    // Dolby Vision is its own sample entry, and every profile the catalogue
    // serves declares PQ. Profiles 7 and 8 carry an HDR10 or HLG base layer,
    // but AVFoundation resolves the base layer from the RPU, not from this.
    if codecs.hasPrefix("dvh1") || codecs.hasPrefix("dvhe") { return "PQ" }

    guard let quality, hdrQualities.contains(quality) else { return nil }
    let hevc = codecs.hasPrefix("hev1") || codecs.hasPrefix("hvc1")
    let av1 = codecs.hasPrefix("av01")
    guard hevc || av1 else { return nil }
    let tenBit = codecs.contains("hvc1.2") || codecs.contains("hev1.2")
      || (av1 && codecs.split(separator: ".").count > 3
            && codecs.split(separator: ".")[3] == "10")
    guard tenBit else { return nil }
    // HDR10/PQ is what the catalogue serves on these rungs; HLG would have to
    // come from the media, and if the media had said, this would not be called.
    return "PQ"
  }
}
