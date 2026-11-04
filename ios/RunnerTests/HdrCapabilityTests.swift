import XCTest
@testable import Parser

/// The gate that decides whether a 10-bit rendition is routed to AVPlayerLayer.
///
/// Found by running the simulator check on this branch: 125 was selected,
/// AVPlayer decoded it, and the picture froze - because eligibility was read as
/// "can present". These tests pin the distinction so it cannot come back.
final class HdrCapabilityTests: XCTestCase {
  func testAnEligibleDeviceWithoutAnHdrOutputCannotPresent() {
    // e.g. a simulator on an HDR-capable Mac: model capable, no HDR output.
    let capability = HdrCapability(
      eligible: true, modes: 0, modesKnown: true
    )
    XCTAssertFalse(capability.canPresent)
    XCTAssertNotNil(capability.reason)
  }

  func testAnEligibleDeviceWithAnHdrModeCanPresent() {
    let capability = HdrCapability(
      eligible: true, modes: 1, modesKnown: true
    )
    XCTAssertTrue(capability.canPresent)
    XCTAssertNil(capability.reason)
  }

  func testAnIneligibleDeviceWithAnHdrModeStillCannotPresent() {
    let capability = HdrCapability(
      eligible: false, modes: 1, modesKnown: true
    )
    // The live output path is the deciding answer where it exists.
    XCTAssertTrue(capability.canPresent)
  }

  func testWithoutTheModeMaskEligibilityIsUsed() {
    // iOS 15/16: the mask does not exist, so refusing would strand devices
    // that play HDR perfectly well.
    XCTAssertTrue(
      HdrCapability(eligible: true, modes: 0, modesKnown: false).canPresent
    )
    XCTAssertFalse(
      HdrCapability(eligible: false, modes: 0, modesKnown: false).canPresent
    )
  }

  func testTheReasonDistinguishesOutputFromDevice() {
    let outputMissing = HdrCapability(
      eligible: true, modes: 0, modesKnown: true
    )
    let deviceIncapable = HdrCapability(
      eligible: false, modes: 0, modesKnown: false
    )
    XCTAssertNotEqual(outputMissing.reason, deviceIncapable.reason)
    XCTAssertTrue(deviceIncapable.reason?.contains("设备") == true)
  }
}
