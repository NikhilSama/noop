import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import Strand

/// nikhil/custom: the interval-mode workout clock (IntervalWorkout.swift).
final class IntervalWorkoutTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    private var plan43: IntervalPlan { IntervalPlan(workSeconds: 240, restSeconds: 180, rounds: 2) }

    func testBlocksEndOnWorkAndMatchThePresetTotals() {
        XCTAssertEqual(plan43.blockCount, 3)                       // work, rest, work
        XCTAssertEqual(plan43.totalSeconds, 240 + 180 + 240)
        var restFirst = plan43; restFirst.restFirst = true
        XCTAssertEqual(restFirst.blockCount, 4)                    // rest, work, rest, work
        XCTAssertEqual(restFirst.kind(ofBlock: 0), .rest)
        XCTAssertEqual(restFirst.kind(ofBlock: 3), .work)
        let thirties = IntervalPlan().applying(IntervalPresets.thirties)
        XCTAssertEqual(thirties.totalSeconds, IntervalPresets.thirties.totalSeconds)
        XCTAssertEqual(IntervalPlan().applying(IntervalPresets.hiit).totalSeconds, IntervalPresets.hiit.totalSeconds)
    }

    func testCueSequence() {
        var s = IntervalSession(plan: plan43, start: t0)
        XCTAssertEqual(s.openingCue, .work)
        XCTAssertNil(s.tick(at: at(100)))
        XCTAssertEqual(s.tick(at: at(240)), .rest)
        XCTAssertNil(s.tick(at: at(300)))
        XCTAssertEqual(s.tick(at: at(410)), .headsUp)              // 10 s before work, during rest
        XCTAssertNil(s.tick(at: at(415)))                          // only once
        XCTAssertEqual(s.tick(at: at(420)), .work)
        XCTAssertEqual(s.round, 2)
        XCTAssertEqual(s.tick(at: at(660)), .done)
        XCTAssertTrue(s.finished)
        XCTAssertNil(s.tick(at: at(900)))                          // cooldown is silent
        XCTAssertEqual(s.log.map(\.kind), [.work, .rest, .work])
        XCTAssertEqual(s.cueCount, 4)
        XCTAssertEqual([IntervalSession.Cue.work, .rest, .headsUp, .done].map(IntervalSession.loops(for:)), [3, 1, 1, 5])
    }

    func testLateTickCatchesUpAndCuesOnlyTheNewestBlock() {
        var s = IntervalSession(plan: IntervalPlan(workSeconds: 240, restSeconds: 180, rounds: nil), start: t0)
        // Asleep from 0 to 500 s: work ended at 240, rest ended at 420; now 80 s into work #2.
        XCTAssertEqual(s.tick(at: at(500)), .work)
        XCTAssertEqual(s.round, 2)
        XCTAssertEqual(s.remaining(at: at(500)), 160)              // anchored to the planned 420 s boundary
        XCTAssertEqual(s.log.count, 2)
    }

    func testPauseFreezesTheBlock() {
        var s = IntervalSession(plan: plan43, start: t0)
        s.pause(at: at(100))
        XCTAssertNil(s.tick(at: at(1_000)))
        XCTAssertEqual(s.remaining(at: at(1_000)), 140)
        s.resume(at: at(1_000))
        XCTAssertEqual(s.remaining(at: at(1_000)), 140)
        XCTAssertEqual(s.tick(at: at(1_140)), .rest)
    }

    func testSkipStartsTheNextBlockNow() {
        var s = IntervalSession(plan: plan43, start: t0)
        XCTAssertEqual(s.skip(at: at(60)), .rest)
        XCTAssertEqual(s.remaining(at: at(60)), 180)
        XCTAssertTrue(s.log[0].skipped)
        XCTAssertEqual(s.skip(at: at(70)), .work)
        XCTAssertEqual(s.skip(at: at(80)), .done)
        XCTAssertTrue(s.finished)
        XCTAssertNil(s.skip(at: at(90)))
    }

    func testPaceTargetsSkipTheLagAndStopAtCooldown() {
        var s = IntervalSession(plan: plan43, start: t0)
        // 30 s into work: still inside the 60 s climb, nothing expected yet.
        XCTAssertEqual(s.paceTargets(at: at(30)), [0, 0, 0, 0, 0])
        // 120 s into work: 60 s counted toward Z3.
        XCTAssertEqual(s.paceTargets(at: at(120))[2], 1, accuracy: 1e-9)
        // 300 s: work done (3 min Z3) + 60 s into rest (0 s past its lag).
        _ = s.tick(at: at(300))
        XCTAssertEqual(s.paceTargets(at: at(300)), [0, 0, 3, 0, 0])
        _ = s.tick(at: at(2_000))
        XCTAssertTrue(s.finished)
        XCTAssertEqual(s.paceTargets(at: at(2_000)), [0, 2, 6, 0, 0])   // 2 + 3 + 3 minutes past the lag
        XCTAssertEqual(IntervalSession.lagAllowance(blockSeconds: 180), 60)
        XCTAssertEqual(IntervalSession.lagAllowance(blockSeconds: 30), 15)
    }

    func testSessionSurvivesEncoding() throws {
        var s = IntervalSession(plan: plan43, start: t0)
        _ = s.tick(at: at(250))
        s.pause(at: at(260))
        let back = try JSONDecoder().decode(IntervalSession.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testPerSportPrefs() {
        let d = UserDefaults(suiteName: "IntervalWorkoutTests")!
        d.removePersistentDomain(forName: "IntervalWorkoutTests")
        XCTAssertFalse(IntervalWorkoutPrefs.isEnabled(sport: "Elliptical", d))
        XCTAssertEqual(IntervalWorkoutPrefs.plan(sport: "Elliptical", d), IntervalPlan())
        var p = IntervalPlan(); p.workZone = 4
        IntervalWorkoutPrefs.save(p, sport: "Elliptical", d)
        IntervalWorkoutPrefs.setEnabled(true, sport: "Elliptical", d)
        XCTAssertTrue(IntervalWorkoutPrefs.isEnabled(sport: "Elliptical", d))
        XCTAssertFalse(IntervalWorkoutPrefs.isEnabled(sport: "Walking", d))
        XCTAssertEqual(IntervalWorkoutPrefs.plan(sport: "Elliptical", d).workZone, 4)
        IntervalWorkoutPrefs.setEnabled(false, sport: "Elliptical", d)
        XCTAssertFalse(IntervalWorkoutPrefs.isEnabled(sport: "Elliptical", d))
    }

    // MARK: After-workout summary

    /// Z1 100+, Z2 120+, Z3 140+, Z4 160+, Z5 180+.
    private let zones = HRZones.zones(maxHR: 200, customLowerBounds: [100, 120, 140, 160, 180])

    private func entry(startSec: Int, sport: String = "Elliptical", workZone: Int = 3) -> IntervalLogStore.Entry {
        var plan = IntervalPlan(workSeconds: 120, restSeconds: 120, rounds: 2)
        plan.workZone = workZone
        var s = IntervalSession(plan: plan, start: Date(timeIntervalSince1970: TimeInterval(startSec)))
        _ = s.tick(at: Date(timeIntervalSince1970: TimeInterval(startSec + 400)))
        return IntervalLogStore.Entry(startSec: startSec, sport: sport, plan: plan, blocks: s.log)
    }

    func testSummaryPerBlock() {
        let e = entry(startSec: 0)
        // Work at 150 (Z3); rest holds 150 for 30 s, then 130 (Z2); second work at 150.
        let samples = (0..<360).map { t in
            HRSample(ts: t, bpm: (t >= 150 && t < 240) ? 130 : 150)
        }
        let s = IntervalSummary.build(entry: e, samples: samples, zones: zones)
        XCTAssertEqual(s.blocks.map(\.kind), [.work, .rest, .work])
        XCTAssertEqual(s.blocks.map(\.round), [1, 1, 2])
        XCTAssertEqual(s.blocks[0].targetSeconds, 120)
        XCTAssertEqual(s.blocks[1].targetSeconds, 90)
        XCTAssertEqual(s.blocks[1].recoveryBpm, 20)                // 150 at the rest's start, 130 a minute in
        XCTAssertNil(s.blocks[0].recoveryBpm)
        XCTAssertEqual(s.avgWorkHr, 150)
        XCTAssertEqual(s.avgWorkTargetSeconds, 120)
        XCTAssertEqual(s.avgRecoveryBpm, 20)
    }

    func testPreviousMatchesSameActivityAndPlanOnly() {
        let older = entry(startSec: 1_000)
        let otherSport = entry(startSec: 2_000, sport: "Rowing")
        let otherZone = entry(startSec: 3_000, workZone: 4)
        let latest = entry(startSec: 4_000)
        let all = [older, otherSport, otherZone, latest]
        XCTAssertEqual(IntervalSummary.previous(to: latest, in: all)?.startSec, 1_000)
        XCTAssertNil(IntervalSummary.previous(to: older, in: all))
    }
}
