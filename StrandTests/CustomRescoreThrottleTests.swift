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
