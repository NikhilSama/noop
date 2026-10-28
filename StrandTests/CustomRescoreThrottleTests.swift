import XCTest
@testable import Strand

/// nikhil/custom: the battery throttle on the full 21-day re-score.
final class CustomRescoreThrottleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testBackgroundOffloadWithinGapIsDeferred() {
        XCTAssertFalse(RescoreThrottle.shouldRunPostOffload(lastPass: now - 10 * 60, now: now, foreground: false))
        XCTAssertTrue(RescoreThrottle.shouldRunPostOffload(lastPass: now - 31 * 60, now: now, foreground: false))
        XCTAssertTrue(RescoreThrottle.shouldRunPostOffload(lastPass: nil, now: now, foreground: false))
    }

    func testForegroundOffloadAlwaysRescores() {
        XCTAssertTrue(RescoreThrottle.shouldRunPostOffload(lastPass: now - 60, now: now, foreground: true))
    }

    func testBackstopRunsWhenOwedOrStale() {
        XCTAssertTrue(RescoreThrottle.shouldRunBackstop(lastPass: now - 60, owed: true, now: now))
        XCTAssertFalse(RescoreThrottle.shouldRunBackstop(lastPass: now - 3600, owed: false, now: now))
        XCTAssertTrue(RescoreThrottle.shouldRunBackstop(lastPass: now - 2 * 3600, owed: false, now: now))
        XCTAssertTrue(RescoreThrottle.shouldRunBackstop(lastPass: nil, owed: false, now: now))
    }

    func testClockMovingBackwardsNeverStarvesARescore() {
        XCTAssertTrue(RescoreThrottle.shouldRunPostOffload(lastPass: now + 600, now: now, foreground: false))
        XCTAssertTrue(RescoreThrottle.shouldRunBackstop(lastPass: now + 600, owed: false, now: now))
    }
}

/// nikhil/custom: the Lift Log ↔ Watch workout overlap test that keeps one copy in Apple Health.
final class CustomLiftWatchWorkoutTests: XCTestCase {
    func testOverlapsMostly() {
        XCTAssertTrue(LiftWatchWorkout.overlapsMostly(0, 3600, 60, 3700))      // same session, watch a bit later
        XCTAssertTrue(LiftWatchWorkout.overlapsMostly(0, 3600, 600, 2400))     // watch inside the lift session
        XCTAssertFalse(LiftWatchWorkout.overlapsMostly(0, 3600, 3000, 9000))   // barely touching
        XCTAssertFalse(LiftWatchWorkout.overlapsMostly(0, 3600, 3600, 7200))   // back to back
    }
}
