import XCTest
@testable import StrandDesign

/// nikhil/custom: the period chosen for the stepped average overlay, and the averages it draws.
final class PeriodAveragesTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2 // Monday
        return c
    }()

    /// Daily points from 2026-01-01 for `days` days, value = day index.
    private func daily(_ days: Int) -> [TrendPoint] {
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        return (0..<days).map { TrendPoint(date: calendar.date(byAdding: .day, value: $0, to: start)!, value: Double($0)) }
    }

    func testPeriodFollowsSpan() {
        XCTAssertNil(PeriodAverages.component(forSpanDays: 6))
        XCTAssertEqual(PeriodAverages.component(forSpanDays: 29), .weekOfYear)
        XCTAssertEqual(PeriodAverages.component(forSpanDays: 60), .weekOfYear)
        XCTAssertEqual(PeriodAverages.component(forSpanDays: 90), .month)
        XCTAssertEqual(PeriodAverages.component(forSpanDays: 182), .month)
        XCTAssertEqual(PeriodAverages.component(forSpanDays: 364), .quarter)
        XCTAssertEqual(PeriodAverages.component(forSpanDays: 1100), .year)
    }

    func testShortSpanHasNoOverlay() {
        XCTAssertTrue(PeriodAverages.segments(for: daily(7), calendar: calendar).isEmpty)
    }

    func testWeeklySegmentsAreCalendarAlignedAndClipped() {
        // 2026-01-01 is a Thursday: first week holds Thu–Sun (values 0…3), then full Mon–Sun weeks.
        let segs = PeriodAverages.segments(for: daily(30), calendar: calendar)
        XCTAssertEqual(segs.count, 5)
        XCTAssertEqual(segs[0].start, daily(1)[0].date)
        XCTAssertEqual(segs[0].average, 1.5)            // (0+1+2+3)/4
        XCTAssertEqual(segs[1].average, 7)              // days 4…10
        XCTAssertEqual(segs.last!.end, daily(30).last!.date)
    }

    func testMonthlyAndQuarterlyCounts() {
        XCTAssertEqual(PeriodAverages.segments(for: daily(181), calendar: calendar).count, 6) // Jan–Jun
        let year = PeriodAverages.segments(for: daily(365), calendar: calendar)
        XCTAssertEqual(year.count, 4)
        XCTAssertEqual(year[0].average, 44.5)           // Jan 1 … Mar 31 = days 0…89
    }
}
