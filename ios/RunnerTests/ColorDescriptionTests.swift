import XCTest
@testable import Parser

/// The `colr` box is the only authoritative source for VIDEO-RANGE.
///
/// Measured on a device: the HLS variant carried no range, so AVFoundation
/// logged the alternate without one and treated a PQ stream as SDR. These build
/// synthetic init segments rather than trusting a codec string.
final class ColorDescriptionTests: XCTestCase {
  /// box(type) with a payload, sized correctly.
  private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
    let size = UInt32(8 + payload.count)
    var out: [UInt8] = [
      UInt8(size >> 24), UInt8((size >> 16) & 0xff),
      UInt8((size >> 8) & 0xff), UInt8(size & 0xff),
    ]
    out.append(contentsOf: Array(type.utf8))
    out.append(contentsOf: payload)
    return out
  }

  private func nclx(primaries: UInt16, transfer: UInt16) -> [UInt8] {
    var payload = Array("nclx".utf8)
    payload.append(contentsOf: [UInt8(primaries >> 8), UInt8(primaries & 0xff)])
    payload.append(contentsOf: [UInt8(transfer >> 8), UInt8(transfer & 0xff)])
    payload.append(contentsOf: [0x00, 0x00, 0x00])
    return box("colr", payload)
  }

  /// Builds moov>trak>mdia>minf>stbl>stsd>entry with the given child boxes.
  private func segment(colr: [UInt8]?) -> Data {
    var entryChildren: [UInt8] = colr ?? []
    let entrySize = UInt32(8 + 78 + entryChildren.count)
    var entry: [UInt8] = [
      UInt8(entrySize >> 24), UInt8((entrySize >> 16) & 0xff),
      UInt8((entrySize >> 8) & 0xff), UInt8(entrySize & 0xff),
    ]
    entry.append(contentsOf: Array("hvc1".utf8))
    entry.append(contentsOf: [UInt8](repeating: 0, count: 78))
    entry.append(contentsOf: entryChildren)

    var stsdPayload: [UInt8] = [0, 0, 0, 0]  // version + flags
    stsdPayload.append(contentsOf: [0, 0, 0, 1])  // entry_count
    stsdPayload.append(contentsOf: entry)
    let stsd = box("stsd", stsdPayload)
    let stbl = box("stbl", stsd)
    let minf = box("minf", stbl)
    let mdia = box("mdia", minf)
    let trak = box("trak", mdia)
    let moov = box("moov", trak)
    let ftyp = box("ftyp", Array("isom".utf8) + [0, 0, 0, 0])
    return Data(ftyp + moov)
  }

  func testPQIsReadAsPQ() {
    let data = segment(colr: nclx(primaries: 9, transfer: 16))
    let described = ColorDescription.read(data)
    XCTAssertEqual(described?.transfer, .pq)
    XCTAssertEqual(described?.primaries, .bt2020)
    XCTAssertEqual(described?.videoRange, "PQ")
    XCTAssertTrue(described?.isHdr == true)
  }

  func testHLGIsReadAsHLGNotPQ() {
    let data = segment(colr: nclx(primaries: 9, transfer: 18))
    let described = ColorDescription.read(data)
    XCTAssertEqual(described?.transfer, .hlg)
    XCTAssertEqual(described?.videoRange, "HLG")
    XCTAssertNotEqual(described?.videoRange, "PQ")
  }

  func testAnExplicitSDRTransferIsSDR() {
    let data = segment(colr: nclx(primaries: 1, transfer: 1))
    XCTAssertEqual(ColorDescription.read(data)?.videoRange, "SDR")
  }

  func testNoColrBoxYieldsNoRange() {
    let data = segment(colr: nil)
    let described = ColorDescription.read(data)
    // nil, not SDR: an unlabelled stream has not said what it is.
    XCTAssertNil(described)
  }

  func testAnUnknownTransferCodeIsNotGuessed() {
    let data = segment(colr: nclx(primaries: 9, transfer: 99))
    let described = ColorDescription.read(data)
    XCTAssertEqual(described?.transfer, .unknown)
    XCTAssertNil(described?.videoRange)
  }

  func testTruncatedDataDoesNotCrash() {
    let data = segment(colr: nclx(primaries: 9, transfer: 16))
    XCTAssertNil(ColorDescription.read(data.prefix(20)))
    XCTAssertNil(ColorDescription.read(Data()))
  }
}
