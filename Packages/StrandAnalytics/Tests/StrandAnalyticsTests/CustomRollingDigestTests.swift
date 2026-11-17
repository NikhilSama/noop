import XCTest
@testable import StrandAnalytics

/// nikhil/custom — the rolling seven-day digest Trends shows at the top.
final class CustomRollingDigestTests: XCTestCase {
    func testWindowIsTheSevenDaysEndingOnTheEndDay() {
        // 2026-11-17 is a Tuesday: the calendar week would hold only Mon and Tue.
        var charge: [String: Double] = [:]
        for (i, day) in ["2026-11-11", "2026-11-12", "2026-11-13", "2026-11-14", "2026-11-15", "2026-11-16", "2026-11-17"].enumerated() {
            charge[day] = Double(50 + i)
        }
        charge["2026-11-10"] = 10   // the day before the window: previous seven days only
        charge["2026-11-04"] = 30
        let d = WeeklyDigestEngine.buildRolling(byMetric: [.charge: charge], endDay: "2026-11-17")
        XCTAssertEqual(d.weekStart, "2026-11-11")
        XCTAssertEqual(d.weekEnd, "2026-11-17")
        XCTAssertEqual(d.daysWithData, 7)
        XCTAssertEqual(d.summary(.charge)?.thisWeek.mean ?? 0, 53, accuracy: 0.0001)
        let calendar = WeeklyDigestEngine.build(byMetric: [.charge: charge], anchorDay: "2026-11-17")
        XCTAssertEqual(calendar.weekStart, "2026-11-16")
        XCTAssertEqual(calendar.daysWithData, 2)
    }

    func testUnparseableEndDayIsEmpty() {
        XCTAssertEqual(WeeklyDigestEngine.buildRolling(byMetric: [:], endDay: "nope").daysWithData, 0)
    }
}
