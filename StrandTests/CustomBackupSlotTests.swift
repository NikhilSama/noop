import XCTest
@testable import Strand

/// nikhil/custom: noon / 7 pm folder-backup slots.
final class CustomBackupSlotTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return c
    }
    private func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
    }
    private func ms(_ d: Date) -> Int { Int(d.timeIntervalSince1970 * 1000) }

    func testLatestSlot() {
        XCTAssertEqual(BackupSync.latestSlot(atOrBefore: at(26, 9), calendar: cal), at(25, 19))
        XCTAssertEqual(BackupSync.latestSlot(atOrBefore: at(26, 12), calendar: cal), at(26, 12))
        XCTAssertEqual(BackupSync.latestSlot(atOrBefore: at(26, 18, 59), calendar: cal), at(26, 12))
        XCTAssertEqual(BackupSync.latestSlot(atOrBefore: at(26, 23), calendar: cal), at(26, 19))
    }

    func testSlotDue() {
        // Backed up at 12:10, nothing new due until 19:00.
        XCTAssertFalse(BackupSync.isSlotDue(lastBackupMs: ms(at(26, 12, 10)), now: at(26, 18), calendar: cal))
        XCTAssertTrue(BackupSync.isSlotDue(lastBackupMs: ms(at(26, 12, 10)), now: at(26, 19, 5), calendar: cal))
        // Backed up at 19:05: not due overnight, due again after noon.
        XCTAssertFalse(BackupSync.isSlotDue(lastBackupMs: ms(at(26, 19, 5)), now: at(27, 8), calendar: cal))
        XCTAssertTrue(BackupSync.isSlotDue(lastBackupMs: ms(at(26, 19, 5)), now: at(27, 12, 1), calendar: cal))
        // Never backed up: always due.
        XCTAssertTrue(BackupSync.isSlotDue(lastBackupMs: 0, now: at(26, 9), calendar: cal))
    }

    func testPartialNameIsNeverASnapshotOrRestorable() {
        let name = BackupSync.snapshotName(1_790_000_000_000) + BackupSync.partialSuffix
        XCTAssertFalse(BackupSync.isSnapshot(name))
        XCTAssertFalse(BackupSync.isBackupFile(name))
    }
}
