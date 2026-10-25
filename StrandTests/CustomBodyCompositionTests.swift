import XCTest
@testable import Strand

/// nikhil/custom: fat / lean mass pairing behind the body-composition Key Metrics tiles.
final class CustomBodyCompositionTests: XCTestCase {

    func testPairsEachBodyFatReadingWithLatestPriorWeight() {
        let pts = BodyComposition.series(
            weight: [("2026-10-01", 80), ("2026-10-05", 78)],
            bodyFat: [("2026-09-30", 20), ("2026-10-03", 20), ("2026-10-05", 25)])
        XCTAssertEqual(pts.map(\.day), ["2026-10-03", "2026-10-05"])   // 09-30 has no weight yet
        XCTAssertEqual(pts[0].weightKg, 80)
        XCTAssertEqual(pts[0].fatKg, 16, accuracy: 1e-9)
        XCTAssertEqual(pts[0].leanKg, 64, accuracy: 1e-9)
        XCTAssertEqual(pts[1].fatKg, 19.5, accuracy: 1e-9)
        XCTAssertEqual(pts[1].fatKg + pts[1].leanKg, 78, accuracy: 1e-9)
    }

    func testRejectsImpossibleBodyFat() {
        let pts = BodyComposition.series(weight: [("2026-10-01", 80)],
                                         bodyFat: [("2026-10-02", 0), ("2026-10-03", 140), ("2026-10-04", .nan)])
        XCTAssertTrue(pts.isEmpty)
    }
}
