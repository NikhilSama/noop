import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// nikhil/custom: the minute-by-minute display read (DaytimeStress+Fine.swift).
final class DaytimeStressFineTests: XCTestCase {

    /// 1 Hz HR from 08:00 to 12:00 UTC at a calm 60–64 bpm (a gentle wobble so the day has spread),
    /// with `spikeBpm` from 10:30 to 10:45.
    private func day(spikeBpm: Int = 95) -> [HRSample] {
        (8 * 3_600 ..< 12 * 3_600).map { t in
            let inSpike = t >= 10 * 3_600 + 1_800 && t < 10 * 3_600 + 2_700
            return HRSample(ts: t, bpm: inSpike ? spikeBpm : 60 + (t / 300) % 5)
        }
    }

    /// Walking-intensity gravity (alternating x) over [from, to), still elsewhere in 08:00–12:00.
    private func gravity(walkingFrom from: Int, to: Int) -> [GravitySample] {
        stride(from: 8 * 3_600, to: 12 * 3_600, by: 5).map { t in
            let walking = t >= from && t < to
            return GravitySample(ts: t, x: walking && (t / 5) % 2 == 0 ? 0.5 : 0, y: 0, z: 1)
        }
    }

    private func level(at ts: Int, in points: [DaytimeStress.HourPoint]) -> DaytimeStress.HourPoint? {
        points.first { $0.startTs + DaytimeStress.fineWindowSeconds == ts }
    }

    func testOnePointPerMinuteAcrossTheData() {
        let r = DaytimeStress.analyze(hr: day(), rr: [], includeTimeline: true)
        XCTAssertEqual(r.fineTimeline.count, 4 * 60, accuracy: 2)
        let gaps = zip(r.fineTimeline, r.fineTimeline.dropFirst()).map { $1.startTs - $0.startTs }
        XCTAssertTrue(gaps.allSatisfy { $0 == DaytimeStress.fineStepSeconds })
    }

    func testShortSpikeShowsInTheMinuteLine() {
        let r = DaytimeStress.analyze(hr: day(), rr: [], includeTimeline: true)
        let spike = level(at: 10 * 3_600 + 2_700, in: r.fineTimeline)?.level
        let calm = level(at: 9 * 3_600 + 1_800, in: r.fineTimeline)?.level
        XCTAssertNotNil(spike); XCTAssertNotNil(calm)
        XCTAssertGreaterThanOrEqual(spike!, DaytimeStress.highBandFloor)
        XCTAssertLessThan(calm!, DaytimeStress.highBandFloor)   // calm sits near the 1.5 midpoint, never HIGH
    }

    func testSpikeWhileWalkingIsMasked() {
        let walkFrom = 10 * 3_600 + 1_800, walkTo = 10 * 3_600 + 2_700
        let r = DaytimeStress.analyze(hr: day(), rr: [], gravity: gravity(walkingFrom: walkFrom, to: walkTo),
                                      includeTimeline: true)
        let during = level(at: walkTo, in: r.fineTimeline)
        XCTAssertEqual(during?.maskedForActivity, true)
        XCTAssertNil(during?.level)
        // Still elevated just after the walk: the post-exertion shadow keeps it masked too.
        let after = level(at: walkTo + 300, in: r.fineTimeline)
        XCTAssertEqual(after?.maskedForActivity, true)
    }

    func testHourlyReadIsUnchangedAndOptIn() {
        let with = DaytimeStress.analyze(hr: day(), rr: [], includeTimeline: true)
        let without = DaytimeStress.analyze(hr: day(), rr: [], includeTimeline: false)
        XCTAssertEqual(with.hours, without.hours)
        XCTAssertEqual(without.fineTimeline, without.timeline)
    }
}
