import XCTest
@testable import Strand

/// nikhil/custom: the permanent Coach chat archive and its daily upload naming.
final class CustomCoachChatLogTests: XCTestCase {

    func testMergeUpsertsStreamedTextAndKeepsClearedMessages() {
        var log = CoachChatLog.merge([], snapshot: [("a", "user", "hi"), ("b", "assistant", "Hel")], now: 10)
        log = CoachChatLog.merge(log, snapshot: [("a", "user", "hi"), ("b", "assistant", "Hello")], now: 20)
        XCTAssertEqual(log.map(\.text), ["hi", "Hello"])
        XCTAssertEqual(log[1].firstSeen, 10)
        // After "Clear conversation" the snapshot restarts; archived turns survive.
        log = CoachChatLog.merge(log, snapshot: [("c", "user", "again")], now: 30)
        XCTAssertEqual(log.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(log.map(\.order), [0, 1, 2])
    }

    func testObjectNameIsUserUploadTimeThenDayMonthYear() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let at = cal.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 9, minute: 5))!
        XCTAssertEqual(CoachChatLog.objectName(user: "nikhil", day: "2026-10-28", uploadedAt: at, calendar: cal),
                       "nikhil-0905-28-10-2026.md")
        XCTAssertEqual(CoachChatLog.objectName(user: "../x", day: "2026-10-28", uploadedAt: at, calendar: cal),
                       "x-0905-28-10-2026.md")
    }

    func testOnlyFinishedUnuploadedDaysUpload() {
        XCTAssertEqual(CoachChatLog.daysToUpload(archived: ["2026-10-28", "2026-10-26", "2026-10-27", "2026-10-29"],
                                                 uploaded: ["2026-10-26"], today: "2026-10-29"),
                       ["2026-10-27", "2026-10-28"])
    }

    func testAfternoonUploadOncePerDayFromFourPM() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        func at(_ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: h, minute: m))! }
        XCTAssertNil(CoachChatLog.afternoonUploadDay(now: at(15, 59), lastDone: nil, calendar: cal))
        XCTAssertEqual(CoachChatLog.afternoonUploadDay(now: at(16, 0), lastDone: "2026-10-28", calendar: cal), "2026-10-29")
        XCTAssertNil(CoachChatLog.afternoonUploadDay(now: at(21, 30), lastDone: "2026-10-29", calendar: cal))
    }

    func testDriveRelayReplyNeedsOkJSON() {
        XCTAssertEqual(CoachDriveRelay.reply(Data(#"{"ok":true,"text":"Be kind"}"#.utf8))?.text, "Be kind")
        XCTAssertEqual(CoachDriveRelay.reply(Data(#"{"ok":true}"#.utf8)), .init(ok: true, text: nil))
        XCTAssertNil(CoachDriveRelay.reply(Data(#"{"ok":false,"error":"bad name"}"#.utf8)))
        XCTAssertNil(CoachDriveRelay.reply(Data("<html>Sign in</html>".utf8)))
    }

    func testDriveRelayUploadURLCarriesTheName() {
        let relay = URL(string: "https://script.google.com/macros/s/abc/exec")!
        XCTAssertEqual(CoachDriveRelay.uploadURL(relay: relay, name: "nikhil-0905-28-10-2026.md")?.absoluteString,
                       "https://script.google.com/macros/s/abc/exec?name=nikhil-0905-28-10-2026.md")
    }

    func testClearLeavesOneDividerBetweenConversations() {
        XCTAssertEqual(CoachChatLog.appendBreak([], now: 5), [])
        var log = CoachChatLog.merge([], snapshot: [("a", "user", "hi")], now: 10)
        log = CoachChatLog.appendBreak(log, now: 20)
        XCTAssertEqual(CoachChatLog.appendBreak(log, now: 30), log)
        log = CoachChatLog.merge(log, snapshot: [("c", "user", "again")], now: 40)
        XCTAssertEqual(log.map(\.role), ["user", CoachChatLog.breakRole, "user"])
        XCTAssertEqual(log.map(\.order), [0, 1, 2])
        let md = CoachChatLog.markdown(.init(day: "2026-10-28", entries: log), user: "nikhil")
        XCTAssertLessThan(md.range(of: "hi")!.lowerBound, md.range(of: "*New conversation · ")!.lowerBound)
        XCTAssertLessThan(md.range(of: "*New conversation · ")!.lowerBound, md.range(of: "again")!.lowerBound)
    }

    func testMarkdownOrdersTurns() {
        let md = CoachChatLog.markdown(.init(day: "2026-10-28", entries: [
            .init(id: "b", role: "assistant", text: "Rest today.", firstSeen: 0, order: 1),
            .init(id: "a", role: "user", text: "Train?", firstSeen: 0, order: 0),
        ]), user: "nikhil")
        XCTAssertLessThan(md.range(of: "Train?")!.lowerBound, md.range(of: "Rest today.")!.lowerBound)
        XCTAssertTrue(md.hasPrefix("# NOOP Coach — nikhil — 2026-10-28"))
    }
}
