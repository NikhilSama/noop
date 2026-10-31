import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import Strand

/// nikhil/custom: the live workout's minutes-per-zone bars.
final class CustomLiveZoneMinutesTests: XCTestCase {

    private let zones = HRZones.zones(maxHR: 200, customLowerBounds: nil)

    private func z(_ zone: Int) -> Int {
        let band = zones.zones.first { $0.number == zone }!
        return Int(((band.lower + band.upper) / 2).rounded())
    }

    func testEachReadingIsCreditedWithTheGapToTheNext() {
        // 120 s in zone 2, then 60 s in zone 4, one reading a second.
        let samples = (0..<120).map { HRSample(ts: $0, bpm: z(2)) } + (120..<180).map { HRSample(ts: $0, bpm: z(4)) }
        let m = LiveZoneMinutes.minutes(samples, zones: zones)
        XCTAssertEqual(m[1], 2, accuracy: 0.001)
        XCTAssertEqual(m[3], 1, accuracy: 0.001)
        XCTAssertEqual(m[0] + m[2] + m[4], 0)
    }

    func testAPauseIsNotCountedAsTimeInTheZoneBeforeIt() {
        let samples = [HRSample(ts: 0, bpm: z(3)), HRSample(ts: 3600, bpm: z(3))]
        XCTAssertEqual(LiveZoneMinutes.minutes(samples, zones: zones)[2], StrainScorer.maxSampleGapMin + 1.0 / 60,
                       accuracy: 0.001)
    }

    func testBelowZoneOneAndEmptyStreamsCountNothing() {
        XCTAssertEqual(LiveZoneMinutes.minutes([], zones: zones), [0, 0, 0, 0, 0])
        XCTAssertEqual(LiveZoneMinutes.minutes([HRSample(ts: 0, bpm: 50)], zones: zones), [0, 0, 0, 0, 0])
    }

    func testLabels() {
        XCTAssertEqual(LiveZoneMinutes.label(0.5), "30s")
        XCTAssertEqual(LiveZoneMinutes.label(12.4), "12m")
    }
}
