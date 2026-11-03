import XCTest
import WhoopStore
@testable import Strand

/// nikhil/custom: "Log what you did" — the Coach reply parser for a finished session, the set rows it
/// files, the vocabulary precedence and which Lift Log session belongs to a workout.
final class CustomCoachSessionParserTests: XCTestCase {

    func testParsesPerSetRepsWeightsAndMuscles() throws {
        let reply = """
        Here you go:
        {"name": "Leg day", "note": "knee felt fine", "exercises": [
          {"exercise": "Back squat", "primary_muscle": "quads", "secondary_muscles": ["glutes", "quads"],
           "weight_unit": "kg", "sets": [{"reps": 10, "weight": 40, "warmup": true},
                                          {"reps": "10", "weight": 60}, {"reps": 8, "weight": 60.0}]},
          {"exercise": "Walking lunge", "primary_muscle": "glutes", "secondary_muscles": [],
           "weight_unit": null, "sets": [{"reps": 12, "weight": null}, {"reps": 9, "weight": null}]}
        ]}
        """
        let (session, warnings) = try CoachSessionParser.parse(reply)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(session.name, "Leg day")
        XCTAssertEqual(session.note, "knee felt fine")
        XCTAssertEqual(session.exercises.count, 2)
        let squat = session.exercises[0]
        XCTAssertEqual(squat.primaryMuscle, .quads)
        XCTAssertEqual(squat.secondaryMuscles, [.glutes], "the primary is never repeated as secondary")
        XCTAssertEqual(squat.sets, [LoggedSet(weightKg: 40, reps: 10, isWarmup: true),
                                    LoggedSet(weightKg: 60, reps: 10), LoggedSet(weightKg: 60, reps: 8)])
        XCTAssertEqual(session.exercises[1].sets, [LoggedSet(weightKg: nil, reps: 12), LoggedSet(weightKg: nil, reps: 9)])
    }

    func testPoundsConvertAndBadValuesAreDroppedWithAWarning() throws {
        let reply = """
        {"name": "", "exercises": [{"exercise": "Curl", "primary_muscle": "biceps", "secondary_muscles": ["wings"],
         "weight_unit": "lb", "sets": [{"reps": 12, "weight": 25}, {"reps": 400, "weight": 25}]}]}
        """
        let (session, warnings) = try CoachSessionParser.parse(reply)
        XCTAssertEqual(session.name, "Strength session")
        XCTAssertEqual(session.exercises[0].sets[0].weightKg, 11.3)
        XCTAssertNil(session.exercises[0].sets[1].reps)
        XCTAssertEqual(session.exercises[0].secondaryMuscles, [])
        XCTAssertEqual(warnings.count, 2)
    }

    func testAnExerciseWithNoSetsGetsOneBlankSetAndJunkIsRejected() throws {
        let (session, _) = try CoachSessionParser.parse(#"{"name": "x", "exercises": [{"exercise": "Plank"}]}"#)
        XCTAssertEqual(session.exercises[0].sets, [LoggedSet()])
        XCTAssertThrowsError(try CoachSessionParser.parse("no json here"))
        XCTAssertThrowsError(try CoachSessionParser.parse(#"{"name": "x", "exercises": []}"#))
    }

    func testSetRowsNumberPerExerciseAndSkipSetsWithoutReps() {
        let session = LoggedSession(name: "s", note: nil, exercises: [
            LoggedExercise(exercise: "Squat", primaryMuscle: .quads, secondaryMuscles: [.glutes],
                           sets: [LoggedSet(weightKg: 60, reps: 10), LoggedSet(weightKg: 60, reps: nil)]),
            LoggedExercise(exercise: "Row", primaryMuscle: nil, secondaryMuscles: [],
                           sets: [LoggedSet(weightKg: 30, reps: 12)]),
            LoggedExercise(exercise: "Squat", primaryMuscle: .quads, secondaryMuscles: [.glutes],
                           sets: [LoggedSet(weightKg: 40, reps: 15)]),
        ])
        let rows = LiftSessionCoachLog.setRows(session, sessionId: "S", deviceId: "D")
        XCTAssertEqual(rows.map(\.exercise), ["Squat", "Row", "Squat"])
        XCTAssertEqual(rows.map(\.ord), [0, 1, 2])
        XCTAssertEqual(rows.map(\.setIndex), [1, 1, 2], "a returned-to exercise carries on its numbering")
        XCTAssertEqual(rows[0].secondaryMuscles, [.glutes])
        XCTAssertTrue(rows.allSatisfy { $0.sessionId == "S" && $0.deviceId == "D" })
    }

    func testVocabularyMatchesIgnoringCaseSpacingAndHyphens() {
        let known = [LiftExerciseRow(id: "1", deviceId: "D", name: "Romanian Deadlift", primaryMuscle: .hamstrings,
                                     secondaryMuscles: [.glutes], createdAt: 0, lastUsedTs: nil)]
        let hit = CoachVocabulary.lookup("romanian  deadlift", in: known)
        XCTAssertEqual(hit?.name, "Romanian Deadlift")
        XCTAssertEqual(hit?.primaryMuscle, .hamstrings)
        XCTAssertEqual(CoachVocabulary.lookup("Romanian-deadlift", in: known)?.name, "Romanian Deadlift")
        XCTAssertNil(CoachVocabulary.lookup("Deadlift", in: known))
    }

    func testSessionForWorkoutPrefersTheExactKeyThenMostlyOverlapping() {
        func session(_ id: String, _ start: Int, _ end: Int) -> LiftSessionRow {
            LiftSessionRow(id: id, deviceId: "D", startTs: start, endTs: end, sport: "Strength Training",
                           programId: nil, programName: nil, sessionRpe: nil, note: nil)
        }
        let workout = WorkoutRow(startTs: 1000, endTs: 4600, sport: "Strength Training", source: "apple",
                                 durationS: 3600, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                                 distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
        let live = session("live", 990, 4500)
        let exact = session("exact", 1000, 4600)
        let earlier = session("earlier", 0, 1100)
        XCTAssertEqual(LiftSessionAttachment.session(for: workout, in: [live, exact])?.id, "exact")
        XCTAssertEqual(LiftSessionAttachment.session(for: workout, in: [earlier, live])?.id, "live")
        XCTAssertNil(LiftSessionAttachment.session(for: workout, in: [earlier]))
    }

    func testAttachmentMarkRoundTrips() {
        let defaults = UserDefaults(suiteName: "CustomCoachSessionParserTests")!
        defaults.removePersistentDomain(forName: "CustomCoachSessionParserTests")
        XCTAssertFalse(LiftSessionAttachment.isAttached(startTs: 5, sport: "Strength Training", defaults: defaults))
        LiftSessionAttachment.mark(startTs: 5, sport: "Strength Training", defaults: defaults)
        LiftSessionAttachment.mark(startTs: 5, sport: "Strength Training", defaults: defaults)
        XCTAssertTrue(LiftSessionAttachment.isAttached(startTs: 5, sport: "Strength Training", defaults: defaults))
        XCTAssertEqual(defaults.stringArray(forKey: LiftSessionAttachment.key)?.count, 1)
        LiftSessionAttachment.unmark(startTs: 5, sport: "Strength Training", defaults: defaults)
        XCTAssertFalse(LiftSessionAttachment.isAttached(startTs: 5, sport: "Strength Training", defaults: defaults))
    }

    func testSetsCardShowsForStrengthAndGenericWorkoutsOnly() {
        for sport in ["Strength", "Bodybuilding", "Strength Training", "Functional Fitness", "Weightlifting", "Workout", "Activity"] {
            XCTAssertTrue(WorkoutLiftSetsCard.applies(to: sport), sport)
        }
        for sport in ["Walking", "Running", "Elliptical", "Yoga"] {
            XCTAssertFalse(WorkoutLiftSetsCard.applies(to: sport), sport)
        }
    }

    func testProgramBecomesAReviewableSession() {
        let program = LiftProgramRow(id: "p", deviceId: "d", name: "Upper A", note: nil,
                                     createdAt: 0, updatedAt: 0, archived: false)
        func item(_ ord: Int, _ name: String, sets: Int?, low: Int?, high: Int?, kg: Double?) -> LiftProgramItemRow {
            LiftProgramItemRow(id: "\(ord)", deviceId: "d", programId: "p", ord: ord, exercise: name,
                               targetSets: sets, targetRepsLow: low, targetRepsHigh: high, targetRpe: nil,
                               targetWeightKg: kg, restSec: nil, note: nil)
        }
        let s = LiftSessionCoachLog.session(fromProgram: program, items: [
            item(1, "Row", sets: nil, low: nil, high: 12, kg: nil),
            item(0, "Bench", sets: 3, low: 8, high: 10, kg: 40),
        ])
        XCTAssertEqual(s.name, "Upper A")
        XCTAssertEqual(s.exercises.map(\.exercise), ["Bench", "Row"])
        XCTAssertEqual(s.exercises[0].sets, Array(repeating: LoggedSet(weightKg: 40, reps: 8), count: 3))
        XCTAssertEqual(s.exercises[1].sets, [LoggedSet(weightKg: nil, reps: 12)])
    }
}
