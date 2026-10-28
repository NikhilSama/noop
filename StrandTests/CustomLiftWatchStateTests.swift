import XCTest
@testable import Strand

/// nikhil/custom: the watch Lift Log screen's state and its button, applied on the phone.
@MainActor
final class CustomLiftWatchStateTests: XCTestCase {

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

    func testWarmupFocusesFirstSetWithTargetsPrefilled() throws {
        let s = try XCTUnwrap(controller().watchState(imperial: false))
        XCTAssertEqual(s.stage, .warmup)
        XCTAssertEqual(s.exercise, "Bench")
        XCTAssertEqual(s.setIndex, 1)
        XCTAssertEqual(s.setCount, 2)
        XCTAssertEqual(s.weightKg, 60)
        XCTAssertEqual(s.reps, 8)
    }

    func testWatchButtonStartsThenCompletesTheSetWithEditedNumbers() throws {
        let c = controller()
        let first = LiftSlot(exerciseIndex: 0, setIndex: 1)
        c.applyWatchAction(first, weightKg: 60, reps: 8)              // Start set
        XCTAssertEqual(c.watchState(imperial: false)?.stage, .working)
        c.applyWatchAction(first, weightKg: 62.5, reps: 7)            // Done, edited on the crown
        let recorded = try XCTUnwrap(c.engine?.recordedSet(for: first))
        XCTAssertEqual(recorded.weightKg, 62.5)
        XCTAssertEqual(recorded.reps, 7)
        let resting = try XCTUnwrap(c.watchState(imperial: false))
        XCTAssertEqual(resting.stage, .resting)
        XCTAssertEqual(resting.setIndex, 2)                            // focus moves to the next set
        XCTAssertEqual(resting.weightKg, 62.5)                         // carried from set 1
    }

    func testStalePressForAnotherSetWhileWorkingDoesNothing() {
        let c = controller()
        c.applyWatchAction(LiftSlot(exerciseIndex: 0, setIndex: 1), weightKg: 60, reps: 8)
        c.applyWatchAction(LiftSlot(exerciseIndex: 1, setIndex: 1), weightKg: 50, reps: 10)
        XCTAssertEqual(c.engine?.stage, .working(LiftSlot(exerciseIndex: 0, setIndex: 1)))
    }
}
