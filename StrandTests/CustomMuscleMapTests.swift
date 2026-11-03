import XCTest
import WhoopStore
@testable import Strand

/// nikhil/custom: the muscle map's colour rules (MuscleMap.swift).
final class CustomMuscleMapTests: XCTestCase {
    private func set(_ primary: LiftMuscle?, _ secondary: [LiftMuscle] = [], reps: Int? = 10,
                     warmup: Bool = false) -> LiftSetRow {
        LiftSetRow(id: UUID().uuidString, deviceId: "d", sessionId: "s", ord: 0, exercise: "x",
                   primaryMuscle: primary, secondaryMuscles: secondary, setIndex: 1, weightKg: 20,
                   reps: reps, rpe: nil, isWarmup: warmup, startTs: nil, endTs: nil, restSec: nil, note: nil)
    }

    func testRecoveryTones() {
        XCTAssertEqual(MuscleMapModel.recoveryTone(daysAgo: 0), .red)
        XCTAssertEqual(MuscleMapModel.recoveryTone(daysAgo: 1), .red)
        XCTAssertEqual(MuscleMapModel.recoveryTone(daysAgo: 2), .yellow)
        XCTAssertEqual(MuscleMapModel.recoveryTone(daysAgo: 3), .yellow)
        XCTAssertEqual(MuscleMapModel.recoveryTone(daysAgo: 4), .green)
        XCTAssertEqual(MuscleMapModel.recoveryTone(daysAgo: nil), .green)
    }

    func testWeeklyTones() {
        XCTAssertEqual(MuscleMapModel.weeklyTone(sets: 0), .red)
        XCTAssertEqual(MuscleMapModel.weeklyTone(sets: 3.5), .red)
        XCTAssertEqual(MuscleMapModel.weeklyTone(sets: 4), .yellow)
        XCTAssertEqual(MuscleMapModel.weeklyTone(sets: 9.5), .yellow)
        XCTAssertEqual(MuscleMapModel.weeklyTone(sets: 10), .green)
    }

    func testLastWorkedNeedsAFullSetsCreditAndTakesTheMostRecentDay() {
        let last = MuscleMapModel.lastWorked(days: [
            (daysAgo: 3, sets: [set(.chest), set(.quads)]),
            (daysAgo: 1, sets: [set(.chest, [.triceps])]),             // triceps only half a set
            (daysAgo: 0, sets: [set(.lats, [.biceps]), set(.lats, [.biceps]), set(.abs, warmup: true)]),
        ])
        XCTAssertEqual(last[.chest], 1)
        XCTAssertEqual(last[.quads], 3)
        XCTAssertNil(last[.triceps])
        XCTAssertEqual(last[.biceps], 0)                                  // two half sets the same day
        XCTAssertEqual(last[.lats], 0)
        XCTAssertNil(last[.abs])                                          // warm-up doesn't count
    }
}
