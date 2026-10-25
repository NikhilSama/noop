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

    func testThirtiesIsRestFirstTenMinutesWithCountedCues() {
        let p = IntervalPresets.thirties
        XCTAssertTrue(p.restFirst)
        XCTAssertTrue(p.countedCues)
        XCTAssertEqual(p.totalSeconds, 600)               // 10 × (30 s rest + 30 s work)
        XCTAssertEqual(p.summary, "rest 0:30 → 0:30 × 10")
        XCTAssertEqual(IntervalPresets.hiit.totalSeconds, 6 * 240 + 5 * 180)
        XCTAssertTrue(IntervalPresets.quick.contains(p))
        XCTAssertTrue(IntervalPresets.watch.contains(p))
    }

    func testCountdownTicksSkippedOnShortPhases() {
        XCTAssertFalse(IntervalPresets.countdownTicks(phaseSeconds: 4))
        XCTAssertFalse(IntervalPresets.countdownTicks(phaseSeconds: 10))
        XCTAssertTrue(IntervalPresets.countdownTicks(phaseSeconds: 15))
        XCTAssertTrue(IntervalPresets.countdownTicks(phaseSeconds: 240))
    }
}
