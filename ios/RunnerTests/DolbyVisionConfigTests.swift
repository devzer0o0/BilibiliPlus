import XCTest

/// A `dvcC` box is the only place the Dolby Vision profile is stated.
///
/// Getting the bit layout wrong is silent: profile 5 and profile 8 are both
/// ten-bit HEVC with an identical codec string, and only the base layer decides
/// whether a renderer that ignores the RPU produces a correct picture.
final class DolbyVisionConfigTests: XCTestCase {
  /// Minimal `moov > trak > mdia > minf > stbl > stsd` holding one `hvc1` entry
  /// with the given child boxes.
  private func initSegment(children: [(String, [UInt8])]) -> Data {
    func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
      var out = be32(UInt32(payload.count + 8))
      out += Array(type.utf8)
      out += payload
      return out
    }
    // 78-byte visual sample entry header, all zeroes is fine here.
    var entry = [UInt8](repeating: 0, count: 78)
    for (type, payload) in children { entry += box(type, payload) }
    var entryWithHeader = be32(UInt32(entry.count + 8))
    entryWithHeader += Array("hvc1".utf8)
    entryWithHeader += entry
    // stsd payload is version+flags, then entry_count, then the entries.
    var stsd: [UInt8] = [0, 0, 0, 0]
    stsd += be32(1)
    stsd += entryWithHeader
    var trak = box("stsd", stsd)
    trak = box("stbl", trak)
    trak = box("minf", trak)
    trak = box("mdia", trak)
    trak = box("trak", trak)
    return Data(box("moov", trak))
  }

  /// Builds a `dvcC` payload: version, then the packed profile/level/flags.
  private func dvcC(profile: Int, level: Int, rpu: Bool, el: Bool, bl: Bool) -> [UInt8] {
    var out: [UInt8] = [0, 1, 0, 0]  // version 1.0
    out.append(UInt8((profile << 1) | ((level >> 5) & 0x01)))
    out.append(UInt8(((level & 0x1F) << 3) | (rpu ? 0x04 : 0) | (el ? 0x02 : 0)))
    out.append(UInt8(bl ? 0x80 : 0x00))
    return out
  }

  private func colrBT2020PQ() -> [UInt8] {
    // nclx, primaries 9 (BT.2020), transfer 16 (PQ), matrix 9, full range 0.
    [0x6E, 0x63, 0x6C, 0x78, 0, 9, 0, 16, 0, 9, 0x00]
  }

  private func be32(_ v: UInt32) -> [UInt8] {
    [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
  }

  func testProfile5IsReadFromThePackedBits() {
    let data = initSegment(children: [
      ("colr", colrBT2020PQ()),
      ("dvcC", dvcC(profile: 5, level: 6, rpu: true, el: false, bl: true)),
    ])
    let described = ColorDescription.read(data)
    XCTAssertEqual(described?.dolbyVision?.profile, 5)
    XCTAssertEqual(described?.dolbyVision?.level, 6)
    XCTAssertEqual(described?.transfer, .pq)
    XCTAssertEqual(described?.dolbyVision?.isProfile5, true)
    XCTAssertEqual(described?.dolbyVision?.hasCompatibleBaseLayer, false)
  }

  func testProfile8KeepsACompatibleBaseLayer() {
    let data = initSegment(children: [
      ("colr", colrBT2020PQ()),
      ("dvcC", dvcC(profile: 8, level: 6, rpu: true, el: false, bl: true)),
    ])
    let described = ColorDescription.read(data)
    XCTAssertEqual(described?.dolbyVision?.profile, 8)
    XCTAssertEqual(described?.dolbyVision?.isProfile5, false)
    XCTAssertEqual(described?.dolbyVision?.hasCompatibleBaseLayer, true)
  }

  func testDvRecordBeforeColrIsStillMerged() {
    // The two boxes are independent; a fixed order inside the entry is not
    // guaranteed by the spec and real files differ.
    let data = initSegment(children: [
      ("dvcC", dvcC(profile: 5, level: 6, rpu: true, el: false, bl: true)),
      ("colr", colrBT2020PQ()),
    ])
    let described = ColorDescription.read(data)
    XCTAssertEqual(described?.dolbyVision?.profile, 5)
    XCTAssertEqual(described?.transfer, .pq)
  }

  func testDvvCIsAcceptedLikeDvcC() {
    let data = initSegment(children: [
      ("colr", colrBT2020PQ()),
      ("dvvC", dvcC(profile: 8, level: 9, rpu: true, el: false, bl: true)),
    ])
    XCTAssertEqual(ColorDescription.read(data)?.dolbyVision?.profile, 8)
  }

  func testFlagsAreDecoded() {
    let data = initSegment(children: [
      ("colr", colrBT2020PQ()),
      ("dvcC", dvcC(profile: 7, level: 9, rpu: true, el: true, bl: true)),
    ])
    let dv = ColorDescription.read(data)?.dolbyVision
    XCTAssertEqual(dv?.profile, 7)
    XCTAssertEqual(dv?.rpuPresent, true)
    XCTAssertEqual(dv?.elPresent, true)
    XCTAssertEqual(dv?.blPresent, true)
  }

  func testNoDvRecordLeavesItNil() {
    let data = initSegment(children: [("colr", colrBT2020PQ())])
    XCTAssertNil(ColorDescription.read(data)?.dolbyVision)
  }

  func testTruncatedDvRecordIsRefusedNotGuessed() {
    let data = initSegment(children: [
      ("colr", colrBT2020PQ()),
      ("dvcC", [0, 1, 0, 0]),  // version only, no profile bytes
    ])
    XCTAssertNil(ColorDescription.read(data)?.dolbyVision)
  }
}
