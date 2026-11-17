import XCTest
import WhoopStore
@testable import Strand

/// nikhil/custom: skipping a set for one session (the watch's skip button).
@MainActor
final class CustomLiftSkipTests: XCTestCase {

    private func controller() -> LiftSessionController {
        let c = LiftSessionController(buzz: { _ in }, setStrapHandler: { _ in })
        c.start(plan: [LiftPlanItem(exercise: "Bench", targetSets: 2, restSec: 90, targetRepsLow: 8, targetWeightKg: 60),
                       LiftPlanItem(exercise: "Row", targetSets: 1, targetRepsLow: 10, targetWeightKg: 50)],
                programId: nil, programName: nil)
        return c
    }

    override func tearDown() {
        LiftSessionPersistence.clear()
        super.tearDown()
    }

    func testSkipInWarmupMovesFocusAndKeepsPlan() throws {
        let c = controller()
        c.skipFromWatch(LiftSlot(exerciseIndex: 0, setIndex: 1))
        let s = try XCTUnwrap(c.watchState(imperial: false))
        XCTAssertEqual(s.stage, .warmup)
        XCTAssertEqual(s.exerciseIndex, 0)
        XCTAssertEqual(s.setIndex, 2)
        XCTAssertEqual(c.engine?.plan[0].targetSets, 2, "the program's set count is untouched")
        XCTAssertTrue(c.engine?.isSkipped(LiftSlot(exerciseIndex: 0, setIndex: 1)) == true)
    }

    func testSkipDuringRestSkipsUpcomingAndRestKeepsRunning() throws {
        let c = controller()
        c.advance()           // start Bench 1
        c.advance()           // done → resting, upcoming Bench 2
        c.skipFromWatch(LiftSlot(exerciseIndex: 0, setIndex: 2))
        let s = try XCTUnwrap(c.watchState(imperial: false))
        XCTAssertEqual(s.stage, .resting)
        XCTAssertEqual(s.exercise, "Row")
        c.advance()           // rest over → Row 1
        XCTAssertEqual(c.engine?.stage, .working(LiftSlot(exerciseIndex: 1, setIndex: 1)))
    }

    func testStaleSkipAndMidSetSkipDoNothing() {
        let c = controller()
        c.skipFromWatch(LiftSlot(exerciseIndex: 1, setIndex: 1))   // not the focus
        XCTAssertEqual(c.engine?.skipped, [])
        c.advance()                                                // working Bench 1
        c.skipFromWatch(LiftSlot(exerciseIndex: 0, setIndex: 1))
        XCTAssertEqual(c.engine?.skipped, [])
    }

    func testSkipIsNotUnfinishedAndSavesAsNotPerformed() {
        let c = controller()
        c.skipFromWatch(LiftSlot(exerciseIndex: 0, setIndex: 1))
        XCTAssertEqual(c.unfinishedSlots, [LiftSlot(exerciseIndex: 0, setIndex: 2), LiftSlot(exerciseIndex: 1, setIndex: 1)])
        let saved = c.setsToSave(completingUnfinished: true)
        let skipped = saved.first { $0.slot == LiftSlot(exerciseIndex: 0, setIndex: 1) }
        XCTAssertEqual(skipped?.reps, 0)
        XCTAssertEqual(skipped?.weightKg, 0)
        XCTAssertEqual(saved.first { $0.slot == LiftSlot(exerciseIndex: 0, setIndex: 2) }?.reps, 8)
    }

    func testStartingASkippedSetTakesItBackAndUndoRestoresSkip() {
        var e = LiftSessionEngine(plan: [LiftPlanItem(exercise: "Bench", targetSets: 2)], startTs: 1_790_000_000)
        let s1 = LiftSlot(exerciseIndex: 0, setIndex: 1)
        XCTAssertTrue(e.skip(s1))
        XCTAssertEqual(e.nextPendingSlot, LiftSlot(exerciseIndex: 0, setIndex: 2))
        e.start(s1, now: 1_790_000_100)
        XCTAssertFalse(e.isSkipped(s1))
        e.undo()
        XCTAssertTrue(e.isSkipped(s1))
        e.undo()
        XCTAssertFalse(e.isSkipped(s1))
    }

    func testSkippingEverythingLeavesNothingPending() {
        var e = LiftSessionEngine(plan: [LiftPlanItem(exercise: "Bench", targetSets: 1)], startTs: 1_790_000_000)
        e.skip(LiftSlot(exerciseIndex: 0, setIndex: 1))
        XCTAssertTrue(e.allCompleted)
        XCTAssertNil(e.nextPendingSlot)
    }

    func testSkipSurvivesPersistence() {
        var e = LiftSessionEngine(plan: [LiftPlanItem(exercise: "Bench", targetSets: 2)], startTs: 1_790_000_000)
        e.skip(LiftSlot(exerciseIndex: 0, setIndex: 2))
        let snap = LiftSessionPersistence.snapshot(engine: e, programId: nil, programName: nil,
                                                   pendingValues: [:], pendingWarmups: [])
        let back = LiftSessionPersistence.engine(from: LiftSessionPersistence.decode(LiftSessionPersistence.encode(snap))!)
        XCTAssertEqual(back.skipped, [LiftSlot(exerciseIndex: 0, setIndex: 2)])
    }

    func testWatchActionDecodesWithoutSkip() throws {
        let old = #"{"exerciseIndex":0,"setIndex":1,"weightKg":60,"reps":8}"#.data(using: .utf8)!
        XCTAssertNil(try XCTUnwrap(LiftWatchAction.decode(old)).skip)
        let skip = LiftWatchAction(exerciseIndex: 0, setIndex: 1, skip: true)
        XCTAssertEqual(LiftWatchAction.decode(skip.encoded())?.skip, true)
    }
}

/// nikhil/custom: nightly sleep split by stage for the stacked charts.
final class CustomSleepStageTrendTests: XCTestCase {

    private func day(_ key: String, total: Double?, deep: Double?, rem: Double?, light: Double?) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: total, efficiency: nil, deepMin: deep, remMin: rem, lightMin: light,
                    disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil)
    }

    func testNightSplitsStagesAndUnstagedRemainder() throws {
        let n = try XCTUnwrap(SleepStageTrend.night(day("2026-11-10", total: 480, deep: 60, rem: 90, light: 300)))
        XCTAssertEqual(n.deep, 1, accuracy: 1e-9)
        XCTAssertEqual(n.rem, 1.5, accuracy: 1e-9)
        XCTAssertEqual(n.light, 5, accuracy: 1e-9)
        XCTAssertEqual(n.unstaged, 0.5, accuracy: 1e-9)
        XCTAssertEqual(n.total, 8, accuracy: 1e-9)
        let unstagedNight = try XCTUnwrap(SleepStageTrend.night(day("2026-11-11", total: 420, deep: nil, rem: nil, light: nil)))
        XCTAssertEqual(unstagedNight.unstaged, 7, accuracy: 1e-9)
        XCTAssertNil(SleepStageTrend.night(day("2026-11-12", total: 0, deep: nil, rem: nil, light: nil)))
    }

    func testRoundingGapIsNotUnstaged() throws {
        let n = try XCTUnwrap(SleepStageTrend.night(day("2026-11-10", total: 452, deep: 60, rem: 90, light: 300)))
        XCTAssertEqual(n.unstaged, 0)
    }

    func testNightsWindowAndWeeklyAverages() throws {
        let end = try XCTUnwrap(NutritionHistory.date("2026-11-17"))
        let days = (0..<14).map { i -> DailyMetric in
            let key = Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -i, to: end)!)
            return day(key, total: Double(400 + i), deep: 60, rem: 60, light: 60)
        }
        XCTAssertEqual(SleepStageTrend.nights(days, last: 7, endDay: end).count, 7)
        let weeks = SleepStageTrend.weeks(days, count: 2, endDay: end)
        XCTAssertEqual(weeks.count, 2)
        XCTAssertEqual(weeks.map(\.nights), [7, 7])
        XCTAssertEqual(weeks[1].deep, 1, accuracy: 1e-9)
        XCTAssertTrue(weeks[0].start < weeks[1].start)
    }
}
