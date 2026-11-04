import XCTest
import StrandDesign
@testable import Strand

/// nikhil/custom — the hydration plan's hourly pacing and the watch snapshot's arithmetic.
final class CustomHydrationPaceTests: XCTestCase {
    // 3.75 L goal, 1.5 L standard → 2.25 L tracked over 11:00–21:00 = 225 ml an hour.
    private let target = HydrationPace.trackedTarget(goalML: 3750, standardML: 1500)

    func testTrackedTargetIsGoalLessStandard() {
        XCTAssertEqual(target, 2250)
        XCTAssertEqual(HydrationPace.trackedTarget(goalML: 1000, standardML: 1500), 0)
    }

    func testExpectedGrowsByAnEvenShareEachHour() {
        XCTAssertEqual(HydrationPace.expectedML(trackedTargetML: target, startHour: 11, endHour: 21, byHour: 9), 0)
        XCTAssertEqual(HydrationPace.expectedML(trackedTargetML: target, startHour: 11, endHour: 21, byHour: 11), 0)
        XCTAssertEqual(HydrationPace.expectedML(trackedTargetML: target, startHour: 11, endHour: 21, byHour: 12), 225)
        XCTAssertEqual(HydrationPace.expectedML(trackedTargetML: target, startHour: 11, endHour: 21, byHour: 16), 1125)
        XCTAssertEqual(HydrationPace.expectedML(trackedTargetML: target, startHour: 11, endHour: 21, byHour: 23), 2250)
    }

    func testRemindersAreDueOnlyWhereBehind() {
        XCTAssertEqual(HydrationPace.dueHours(trackedML: 0, trackedTargetML: target, startHour: 11, endHour: 21),
                       Array(12...21))
        // Two glasses (500 ml) cover 12:00 and 13:00 (450), not 14:00 (675).
        XCTAssertEqual(HydrationPace.dueHours(trackedML: 500, trackedTargetML: target, startHour: 11, endHour: 21).first, 14)
        XCTAssertEqual(HydrationPace.dueHours(trackedML: 2250, trackedTargetML: target, startHour: 11, endHour: 21), [])
        XCTAssertEqual(HydrationPace.dueHours(trackedML: 0, trackedTargetML: 0, startHour: 11, endHour: 21), [])
    }

    func testABadWindowFallsBack() {
        XCTAssertTrue(HydrationPace.window(startHour: 21, endHour: 11) == (9, 21))
    }

    func testSnapshotSplitsStandardFromTracked() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let snap = WatchHydrationSnapshot(day: WatchHydrationSnapshot.dayKey(Date()), totalML: 1950, standardML: 1500,
                                          standardApplied: true, goalML: 3750, glassML: 250,
                                          windowStartHour: 11, windowEndHour: 21)
        XCTAssertEqual(snap.trackedML, 450)
        XCTAssertEqual(snap.remainingML, 1800)
        let threePM = cal.date(bySettingHour: 15, minute: 30, second: 0, of: Date())!
        XCTAssertEqual(snap.behindML(now: threePM, calendar: cal), 900 - 450)
        XCTAssertEqual(snap.adding(250).totalML, 2200)
    }

    func testANewDayStartsFromTheStandardAmount() {
        let snap = WatchHydrationSnapshot(day: "2000-01-01", totalML: 3000, standardML: 1500, standardApplied: true,
                                          goalML: 3750, glassML: 250, windowStartHour: 11, windowEndHour: 21)
        let today = snap.current()
        XCTAssertEqual(today.totalML, 1500)
        XCTAssertEqual(today.trackedML, 0)
    }

    func testEntriesKeepTheStandardFlagOnEdit() {
        let e = HydrationEntries.adding([], amountMl: 1500, isStandard: true)
        let edited = HydrationEntries.updating(e, id: e[0].id, amountMl: 1250)
        XCTAssertEqual(edited[0].isStandard, true)
        XCTAssertEqual(edited[0].amountMl, 1250)
    }
}
