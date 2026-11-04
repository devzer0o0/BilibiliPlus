import XCTest

/// The DASH index is the difference between "plays the whole track" and "plays
/// the first nineteen fragments". These fixtures are byte-built here, so the
/// assertions do not depend on a downloaded media file.
final class DashIndexTests: XCTestCase {
  private func be32(_ value: UInt32) -> [UInt8] {
    [
      UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
      UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF),
    ]
  }

  private func sidx(
    version: UInt8,
    references: [(size: Int, duration: UInt32, sap: Bool)],
    firstOffset: UInt32 = 0,
    timescale: UInt32 = 1000
  ) -> Data {
    var payload: [UInt8] = [version, 0, 0, 0]
    payload += be32(1)  // reference_ID
    payload += be32(timescale)
    if version == 0 {
      payload += be32(0)  // earliest_presentation_time
      payload += be32(firstOffset)
    } else {
      payload += be32(0)
      payload += be32(0)
      payload += be32(0)
      payload += be32(firstOffset)
    }
    payload += [0, 0]  // reserved
    payload += [UInt8(references.count >> 8 & 0xFF), UInt8(references.count & 0xFF)]
    for reference in references {
      // reference_type(1) | referenced_size(31), duration, SAP word.
      payload += be32(UInt32(reference.size) & 0x7FFF_FFFF)
      payload += be32(reference.duration)
      payload += be32(reference.sap ? 0x9000_0000 : 0x1000_0000)
    }
    return Data(be32(UInt32(payload.count + 8)) + Array("sidx".utf8) + payload)
  }

  func testVersion0ReadsEveryReference() throws {
    let index = try SidxParser.parse(
      sidx(
        version: 0,
        references: [(1000, 5000, true), (2000, 5000, false), (3000, 5000, false)]
      )
    )
    XCTAssertEqual(index.references.count, 3)
    XCTAssertEqual(index.timescale, 1000)
    XCTAssertEqual(index.totalSize, 6000)
    XCTAssertTrue(index.references[0].startsWithSap)
    XCTAssertFalse(index.references[1].startsWithSap)
  }

  func testVersion1UsesSixtyFourBitFields() throws {
    let index = try SidxParser.parse(
      sidx(
        version: 1,
        references: [(700, 3200, true)],
        firstOffset: 24,
        timescale: 90000
      )
    )
    XCTAssertEqual(index.firstOffset, 24)
    XCTAssertEqual(index.references.count, 1)
    // The first fragment starts after the box plus the declared offset, which
    // the old reader dropped entirely.
    XCTAssertEqual(index.offset(of: 0), index.boxEnd + 24)
  }

  /// The index is fetched as its own ranged read, so `boxEnd` is relative to
  /// that slice. The first fragment must start after the slice, not at 260.
  func testOffsetIsAbsoluteWhenTheIndexWasFetchedAsASlice() throws {
    let box = sidx(
      version: 0,
      references: [(100, 1000, true), (200, 1000, false)]
    )
    let index = try SidxParser.parse(box)
    XCTAssertEqual(index.offset(of: 0, sliceStart: 1000), 1000 + box.count)
    XCTAssertEqual(index.offset(of: 1, sliceStart: 1000), 1000 + box.count + 100)
  }

  func testOffsetsAccumulateInOrder() throws {
    let index = try SidxParser.parse(
      sidx(
        version: 0,
        references: [(100, 1000, true), (200, 1000, false), (300, 1000, false)]
      )
    )
    XCTAssertEqual(index.offset(of: 0), index.boxEnd)
    XCTAssertEqual(index.offset(of: 1), index.boxEnd + 100)
    XCTAssertEqual(index.offset(of: 2), index.boxEnd + 300)
  }

  func testTruncatedIndexIsRejected() {
    var data = sidx(
      version: 0,
      references: [(1000, 5000, true), (2000, 5000, false)]
    )
    data = data.prefix(data.count - 4)
    XCTAssertThrowsError(try SidxParser.parse(data))
  }

  func testWrongBoxTypeIsRejected() {
    let notASidx = Data(be32(16) + Array("moof".utf8) + [0, 0, 0, 0])
    XCTAssertThrowsError(try SidxParser.parse(notASidx))
  }

  func testSegmentBaseRangesAreParsed() {
    let base = DashSegmentBase(initialization: "0-999", indexRange: "1000-1259")
    XCTAssertEqual(base?.initialization, 0...999)
    XCTAssertEqual(base?.indexRange, 1000...1259)
    XCTAssertEqual(base?.headerEnd, 1260)
    XCTAssertEqual(base?.firstFragmentOffset, 1260)
  }

  func testInvertedOrMissingRangesAreRejected() {
    XCTAssertNil(DashSegmentBase(initialization: "1000-999", indexRange: "1000-1259"))
    XCTAssertNil(DashSegmentBase(initialization: "0-999", indexRange: nil))
    XCTAssertNil(DashSegmentBase(initialization: "junk", indexRange: "0-9"))
  }
}


final class Mp4BoxPatcherTests: XCTestCase {
  private func be32(_ value: UInt32) -> [UInt8] {
    [
      UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
      UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF),
    ]
  }

  private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
    be32(UInt32(payload.count + 8)) + Array(type.utf8) + payload
  }

  /// An AVC track has no HEVC sample entry. Patching it must be a no-op rather
  /// than a failure: the same code runs for every native source.
  func testNonHevcTrackIsLeftAlone() throws {
    var entry: [UInt8] = Array(repeating: 0, count: 78)
    entry += box("avcC", [1, 2, 3])
    let sampleEntry = be32(UInt32(entry.count + 8)) + Array("avc1".utf8) + entry
    let stsd = box("stsd", [0, 0, 0, 0] + be32(1) + sampleEntry)
    let moov = box("moov", box("trak", box("mdia", box("minf", box("stbl", stsd)))))
    let mdat = box("mdat", Array("hev1 hev1".utf8))
    let file = Data(box("ftyp", Array("isom".utf8)) + moov + mdat)

    let (out, report) = try Mp4BoxPatcher.hvc1(file)
    XCTAssertFalse(report.patched)
    XCTAssertEqual(out, file)
  }

  /// The parameter sets live in hvcC for both fourccs, so swapping the code is
  /// the whole change - and the media bytes must come out byte-identical.
  func testHev1IsRewrittenWithoutTouchingMediaData() throws {
    let hvcC = box("hvcC", [1, 2, 3, 4])
    var entry: [UInt8] = Array(repeating: 0, count: 78)
    entry += hvcC
    let sampleEntry = be32(UInt32(entry.count + 8)) + Array("hev1".utf8) + entry
    let stsd = box("stsd", [0, 0, 0, 0] + be32(1) + sampleEntry)
    let moov = box("moov", box("trak", box("mdia", box("minf", box("stbl", stsd)))))
    let mdatPayload = Array("hev1 in mdat stays".utf8)
    let mdat = box("mdat", mdatPayload)
    let file = Data(box("ftyp", Array("isom".utf8)) + moov + mdat)

    let (out, report) = try Mp4BoxPatcher.hvc1(file)
    XCTAssertTrue(report.patched)
    XCTAssertTrue(report.hasHvcC)
    XCTAssertEqual(out.count, file.count)
    let bytes = [UInt8](out)
    let tail = Array(bytes[(bytes.count - mdatPayload.count)...])
    XCTAssertEqual(tail, mdatPayload, "mdat must be byte-identical")
  }

  /// A box whose declared size runs past the buffer is rejected, not clamped.
  func testTruncatedBoxIsRejected() {
    var file: [UInt8] = be32(64) + Array("moov".utf8)
    file += [0, 0, 0, 0]
    XCTAssertThrowsError(try Mp4BoxPatcher.hvc1(Data(file)))
  }
}
