import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// nikhil/custom: the pure maths behind the hero breakdown pages.
final class CustomBreakdownTests: XCTestCase {

    func testRangeStatsQuantilesAndPercentile() throws {
        let s = try XCTUnwrap(RangeStats([5, 1, 3, 2, 4]))
        XCTAssertEqual(s.min, 1)
        XCTAssertEqual(s.max, 5)
        XCTAssertEqual(s.mean, 3)
        XCTAssertEqual(s.median, 3)
        XCTAssertEqual(s.p25, 2)
        XCTAssertEqual(s.p75, 4)
        XCTAssertEqual(s.percentile(of: 3), 50)   // 2 below + half of 1 tie, of 5
        XCTAssertEqual(s.percentile(of: 6), 100)
        XCTAssertEqual(s.percentile(of: 0), 0)
        XCTAssertNil(RangeStats([]))
        XCTAssertNil(RangeStats([.nan]))
    }

    func testOrdinal() {
        XCTAssertEqual(RangeStrip.ordinal(1), "1st")
        XCTAssertEqual(RangeStrip.ordinal(72), "72nd")
        XCTAssertEqual(RangeStrip.ordinal(13), "13th")
        XCTAssertEqual(RangeStrip.ordinal(23), "23rd")
    }

    func testEffortLoadInvertsTheLogMap() {
        // Effort = 100·ln(T+1)/ln(D)  ⇔  T = D^(Effort/100) − 1
        XCTAssertEqual(EffortSplit.load(0), 0, accuracy: 1e-9)
        XCTAssertEqual(EffortSplit.load(100), StrainScorer.strainDenominator - 1, accuracy: 1e-6)
        let t = EffortSplit.load(60)
        XCTAssertEqual(100 * log(t + 1) / log(StrainScorer.strainDenominator), 60, accuracy: 1e-9)
    }

    func testEffortSplitSharesSumToOneWithEverydayRemainder() {
        let split = EffortSplit(dayEffort: 70, workouts: [workout(55), workout(40)])
        let total = split.items.map(\.share).reduce(0, +) + (split.everydayShare ?? 0)
        XCTAssertEqual(total, 1, accuracy: 1e-9)
        XCTAssertNotNil(split.everydayShare)
        XCTAssertGreaterThan(split.items[0].share, split.items[1].share)
    }

    func testEffortSplitWorkoutsExceedingDayHideEveryday() {
        let split = EffortSplit(dayEffort: 30, workouts: [workout(60)])
        XCTAssertNil(split.everydayShare)
        XCTAssertEqual(split.items[0].share, 1, accuracy: 1e-9)
    }

    func testEffortSplitNoWorkoutsIsAllEveryday() {
        let split = EffortSplit(dayEffort: 40, workouts: [])
        XCTAssertEqual(split.everydayShare ?? 0, 1, accuracy: 1e-9)
    }

    private func workout(_ strain: Double) -> WorkoutRow {
        WorkoutRow(startTs: 0, endTs: 3600, sport: "running", source: "test", durationS: 3600,
                   energyKcal: nil, avgHr: nil, maxHr: nil, strain: strain, distanceM: nil,
                   zonesJSON: nil, notes: nil, steps: nil)
    }
}
