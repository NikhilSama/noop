import XCTest
@testable import Strand

/// nikhil/custom: one-tap interval presets.
final class CustomIntervalPresetTests: XCTestCase {
    func testPresetValues() {
        XCTAssertTrue(IntervalPresets.hiit.matches(work: 240, rest: 180, rounds: 6))
        XCTAssertTrue(IntervalPresets.sprints.matches(work: 6, rest: 4, rounds: 20))
        XCTAssertEqual(IntervalPresets.hiit.summary, "4:00 / 3:00 × 6")
        XCTAssertEqual(IntervalPresets.sprints.summary, "0:06 / 0:04 × 20")
    }

    func testCountdownTicksSkippedOnShortPhases() {
        XCTAssertFalse(IntervalPresets.countdownTicks(phaseSeconds: 4))
        XCTAssertFalse(IntervalPresets.countdownTicks(phaseSeconds: 10))
        XCTAssertTrue(IntervalPresets.countdownTicks(phaseSeconds: 15))
        XCTAssertTrue(IntervalPresets.countdownTicks(phaseSeconds: 240))
    }
}
