import XCTest
@testable import Strand

/// nikhil/custom: the Apple Health write-back only rewrites what changed (battery).
final class CustomHealthWriteDiffTests: XCTestCase {

    func testUnchangedHoursAreSkippedAndChangedHourIsRewritten() {
        let base = 1_800_000_000 - 1_800_000_000 % 3600
        let first = (0..<180).map { (ts: base + $0 * 60, bpm: 60.0) }           // 3 full hours
        let previous = HealthWriteDiff.hourFingerprints(first)
        XCTAssertEqual(previous.count, 3)
        XCTAssertTrue(HealthWriteDiff.changedHours(current: previous, previous: previous, windowStart: base).isEmpty)

        // New minutes arrive in the third hour only.
        let next = first + [(ts: base + 180 * 60, bpm: 70)]
        let current = HealthWriteDiff.hourFingerprints(next)
        XCTAssertEqual(HealthWriteDiff.changedHours(current: current, previous: previous, windowStart: base),
                       [base + 3 * 3600])

        // A backfilled value in the first hour is picked up too.
        var edited = first; edited[5] = (ts: edited[5].ts, bpm: 99)
        XCTAssertEqual(HealthWriteDiff.changedHours(current: HealthWriteDiff.hourFingerprints(edited),
                                                    previous: previous, windowStart: base), [base])
    }

    func testVanishedHourInsideWindowIsCleared() {
        let base = 1_800_000_000 - 1_800_000_000 % 3600
        let previous = [base: "a", base + 3600: "b", base - 7200: "old"]
        XCTAssertEqual(HealthWriteDiff.changedHours(current: [base: "a"], previous: previous, windowStart: base),
                       [base + 3600])
    }

    func testRangesMergeContiguousHours() {
        let r = HealthWriteDiff.ranges(ofHours: [7200, 0, 3600, 14400])
        XCTAssertEqual(r.map(\.start), [0, 14400])
        XCTAssertEqual(r.map(\.end), [10800, 18000])
    }

    func testChangedKeysAndStableHash() {
        XCTAssertEqual(HealthWriteDiff.fnv1a("abc"), HealthWriteDiff.fnv1a("abc"))
        XCTAssertNotEqual(HealthWriteDiff.fnv1a("abc"), HealthWriteDiff.fnv1a("abd"))
        XCTAssertEqual(HealthWriteDiff.changedKeys(current: ["a": "1", "b": "2", "c": "3"],
                                                   previous: ["a": "1", "b": "x"]), ["b", "c"])
    }
}
