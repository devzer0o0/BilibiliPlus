import XCTest
@testable import Parser

/// Dynamic range must be inferred from the rung, never from the bit depth.
///
/// The rule decides what `VIDEO-RANGE` the master playlist declares for a
/// rendition whose init segment has no `colr` box. Declaring PQ for a ten-bit
/// SDR stream makes AVFoundation tone-map an SDR picture as HDR, and the result
/// is reported as "the colours are wrong" - indistinguishable from a decoder
/// fault.
final class ColorRangeTests: XCTestCase {
  func testTenBitSdrAv1DeclaresNothing() {
    // Measured on a device: this exact string is what the catalogue serves for a
    // 4K AV1 rendition that is ten-bit but not HDR.
    XCTAssertNil(
      ColorDescription.rangeWhenUnknown(
        codecs: "av01.0.00M.10.0.110.01.01.01.0",
        quality: 120
      )
    )
  }

  func testEightBitSdrAv1DeclaresNothing() {
    XCTAssertNil(
      ColorDescription.rangeWhenUnknown(
        codecs: "av01.0.13M.08.0.110.01.01.01.0",
        quality: 120
      )
    )
  }

  func testTenBitAv1OnAnHdrRungIsPQ() {
    XCTAssertEqual(
      ColorDescription.rangeWhenUnknown(
        codecs: "av01.0.09M.10.0.110.01.01.01.0",
        quality: 125
      ),
      "PQ"
    )
  }

  func testTenBitHevcOnAnHdrRungIsPQ() {
    XCTAssertEqual(
      ColorDescription.rangeWhenUnknown(
        codecs: "hev1.2.4.L153.90",
        quality: 125
      ),
      "PQ"
    )
  }

  func testEightBitHevcOnAnHdrRungDeclaresNothing() {
    XCTAssertNil(
      ColorDescription.rangeWhenUnknown(
        codecs: "hvc1.1.6.L153.90",
        quality: 125
      )
    )
  }

  func testDolbyVisionIsPQRegardlessOfTheQualityId() {
    XCTAssertEqual(
      ColorDescription.rangeWhenUnknown(codecs: "dvh1.05.09", quality: 126),
      "PQ"
    )
    // The sample entry is definitive on its own; a caller that did not pass a
    // quality id must not lose the answer.
    XCTAssertEqual(
      ColorDescription.rangeWhenUnknown(codecs: "dvh1.05.09", quality: nil),
      "PQ"
    )
  }

  func testAnUnknownQualityDeclaresNothing() {
    XCTAssertNil(
      ColorDescription.rangeWhenUnknown(codecs: "hev1.2.4.L153.90", quality: nil)
    )
    XCTAssertNil(ColorDescription.rangeWhenUnknown(codecs: nil, quality: 125))
    XCTAssertNil(ColorDescription.rangeWhenUnknown(codecs: "", quality: 125))
  }

  func testAvcNeverDeclaresExtendedRange() {
    XCTAssertNil(
      ColorDescription.rangeWhenUnknown(codecs: "avc1.640034", quality: 125)
    )
  }
}
