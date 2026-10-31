import XCTest
import GRDB
@testable import WhoopStore

/// nikhil/custom: folding a re-added strap's archived row into its active row.
final class CustomDuplicateStrapMergeTests: XCTestCase {

    private let pid = "480287B9-5853-F0CD-99AC-0E04E8313F6E"

    /// The reported shape: `my-whoop` (seeded, then archived by the wizard) and the re-added row share the
    /// strap's peripheral, and the night's samples landed under `my-whoop`.
    private func makeReAddedStrap() throws -> (DatabaseQueue, DeviceRegistryStore) {
        let dbq = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbq)   // seeds 'my-whoop' active
        let store = DeviceRegistryStore(dbQueue: dbq)
        try dbq.write { try $0.execute(sql: "UPDATE pairedDevice SET peripheralId = ? WHERE id = 'my-whoop'", arguments: [pid]) }
        try store.add(PairedDevice(id: "whoop-5B00297496", brand: "WHOOP", model: "5.0 MG", peripheralId: pid,
                                   sourceKind: .liveBLE, capabilities: [.hr, .sleep], status: .paired,
                                   addedAt: 200, lastSeenAt: 200))
        try store.setActive("whoop-5B00297496")
        try store.archive("my-whoop")
        return (dbq, store)
    }

    private func sleeps(_ dbq: DatabaseQueue, _ id: String) throws -> Int {
        try dbq.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sleepSession WHERE deviceId = ?", arguments: [id]) ?? 0 }
    }

    private func hr(_ dbq: DatabaseQueue, _ id: String) throws -> [Int] {
        try dbq.read { try Int.fetchAll($0, sql: "SELECT bpm FROM hrSample WHERE deviceId = ? ORDER BY ts", arguments: [id]) }
    }

    func testArchivedDuplicatesRawStreamsMoveAndCanonicalHistoryStays() throws {
        let (dbq, store) = try makeReAddedStrap()
        try dbq.write { db in
            // The night, filed under the archived row; one second also recorded under the active row.
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('my-whoop', 10, 50), ('my-whoop', 11, 51)")
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('whoop-5B00297496', 11, 70)")
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('my-whoop-noop', 12, 52)")
            // Imported history lives under the canonical id and must stay there.
            try db.execute(sql: "INSERT INTO sleepSession (deviceId, startTs, endTs) VALUES ('my-whoop', 100, 200)")
        }

        let merged = try store.mergeArchivedDuplicatesOfActiveStrap()

        XCTAssertEqual(merged, [.init(fromId: "my-whoop", toId: "whoop-5B00297496")])
        XCTAssertEqual(try hr(dbq, "whoop-5B00297496"), [50, 70], "moved, and the active row wins a clash")
        XCTAssertEqual(try hr(dbq, "my-whoop"), [])
        XCTAssertEqual(try hr(dbq, "my-whoop-noop"), [52], "computed rows stay on the canonical sibling")
        XCTAssertEqual(try hr(dbq, "whoop-5B00297496-noop"), [])
        XCTAssertEqual(try sleeps(dbq, "my-whoop"), 1, "imported history stays canonical")
        let old = try store.all().first { $0.id == "my-whoop" }
        XCTAssertEqual(old?.status, .archived, "the registry row stays, archived")
        XCTAssertNil(old?.peripheralId, "and can no longer match a link")
        XCTAssertNil(SourceIdentity.resolve(address: pid, rows: try store.all(), currentId: "whoop-5B00297496"))
    }

    func testSecondRunIsANoOp() throws {
        let (dbq, store) = try makeReAddedStrap()
        try dbq.write { try $0.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('my-whoop', 10, 50)") }
        XCTAssertEqual(try store.mergeArchivedDuplicatesOfActiveStrap().count, 1)
        XCTAssertEqual(try store.mergeArchivedDuplicatesOfActiveStrap(), [])
        XCTAssertEqual(try hr(dbq, "whoop-5B00297496"), [50])
    }

    func testOtherStrapsAndPairedRowsAreLeftAlone() throws {
        let (dbq, store) = try makeReAddedStrap()
        try store.add(PairedDevice(id: "whoop-OTHER", brand: "WHOOP", model: "4.0", peripheralId: "SOMETHING-ELSE",
                                   sourceKind: .liveBLE, capabilities: [.hr], status: .archived,
                                   addedAt: 50, lastSeenAt: 50))
        try dbq.write { try $0.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('whoop-OTHER', 10, 60)") }
        try store.mergeArchivedDuplicatesOfActiveStrap()
        XCTAssertEqual(try hr(dbq, "whoop-OTHER"), [60], "a different strap's archive is not this strap's")
        XCTAssertEqual(try store.all().first { $0.id == "whoop-OTHER" }?.peripheralId, "SOMETHING-ELSE")
    }

    func testCleanRegistryMergesNothing() throws {
        let dbq = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbq)
        XCTAssertEqual(try DeviceRegistryStore(dbQueue: dbq).mergeArchivedDuplicatesOfActiveStrap(), [])
    }

    /// The first build moved everything; the restore puts imported and computed rows back under the
    /// canonical ids, a fresh canonical computed row beating the stale moved copy, and leaves raw alone.
    func testRestorePutsCanonicalHistoryBackAfterTheFullMerge() throws {
        let (dbq, store) = try makeReAddedStrap()
        try dbq.write { db in
            // The footprint of the first build: canonical row archived, peripheral cleared...
            try db.execute(sql: "UPDATE pairedDevice SET peripheralId = NULL WHERE id = 'my-whoop'")
            // ...imported history and stale computed rows moved onto the active strap...
            try db.execute(sql: "INSERT INTO sleepSession (deviceId, startTs, endTs) VALUES ('whoop-5B00297496', 100, 200)")
            try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day) VALUES ('whoop-5B00297496-noop', '2026-10-31')")
            // ...while the engine kept writing fresh computed rows to the canonical sibling.
            try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day, totalSleepMin) VALUES ('my-whoop-noop', '2026-10-31', 457.5)")
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('whoop-5B00297496', 10, 50)")
        }

        XCTAssertTrue(try store.restoreCanonicalHistoryAfterFullMerge())

        XCTAssertEqual(try sleeps(dbq, "my-whoop"), 1)
        XCTAssertEqual(try sleeps(dbq, "whoop-5B00297496"), 0)
        let days = try dbq.read { try Row.fetchAll($0, sql: "SELECT deviceId, totalSleepMin FROM dailyMetric WHERE day = '2026-10-31'") }
        XCTAssertEqual(days.count, 1, "the stale copy is gone")
        XCTAssertEqual(days.first?["deviceId"] as String?, "my-whoop-noop")
        XCTAssertEqual(days.first?["totalSleepMin"] as Double?, 457.5, "the fresh row won")
        XCTAssertEqual(try hr(dbq, "whoop-5B00297496"), [50], "raw stays on the active strap")
        XCTAssertFalse(try store.restoreCanonicalHistoryAfterFullMerge(), "nothing left to move")
    }

    func testRestoreDoesNothingOnASingleStrapInstall() throws {
        let dbq = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbq)   // 'my-whoop' active
        try dbq.write { try $0.execute(sql: "INSERT INTO sleepSession (deviceId, startTs, endTs) VALUES ('my-whoop', 100, 200)") }
        XCTAssertFalse(try DeviceRegistryStore(dbQueue: dbq).restoreCanonicalHistoryAfterFullMerge())
        XCTAssertEqual(try sleeps(dbq, "my-whoop"), 1)
    }
}
