import XCTest
import StrandImport
import WhoopStore
@testable import Strand

/// nikhil/custom: the Lift Log's "Import with Coach" reply parser.
final class CustomCoachProgramParserTests: XCTestCase {

    func testParsesProgramFromFencedReplyWithLoosenedNumbers() throws {
        let reply = """
        Here you go:
        ```json
        {"name": "Leg day", "note": null, "exercises": [
          {"exercise": "Back squat", "primary_muscle": "quads", "secondary_muscles": ["glutes"],
           "sets": 4, "reps": "8", "weight": 80, "weight_unit": "kg", "rest_sec": 120.0, "max_rpe": null, "note": null},
          {"exercise": "Romanian deadlift", "primary_muscle": "hamstrings", "secondary_muscles": [],
           "sets": 3.0, "reps": 10, "weight": 135, "weight_unit": "lb", "rest_sec": null, "max_rpe": 8, "note": "slow down"}
        ]}
        ```
        """
        let (program, warnings) = try CoachProgramParser.parse(reply)
        XCTAssertEqual(program.name, "Leg day")
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(program.lines.map(\.exercise), ["Back squat", "Romanian deadlift"])
        let squat = program.lines[0]
        XCTAssertEqual(squat.primaryMuscle, .quads)
        XCTAssertEqual(squat.secondaryMuscles, [.glutes])
        XCTAssertEqual(squat.targetSets, 4)
        XCTAssertEqual(squat.targetReps, 8)
        XCTAssertEqual(squat.targetWeightKg, 80)
        XCTAssertEqual(squat.restSec, 120)
        let rdl = program.lines[1]
        XCTAssertEqual(rdl.targetSets, 3)
        XCTAssertEqual(rdl.targetWeightKg, 61.2)   // 135 lb, to one decimal of a kilogram
        XCTAssertEqual(rdl.targetMaxRpe, 8)
        XCTAssertEqual(rdl.note, "slow down")
    }

    func testUnknownMusclesAndImpossibleValuesBecomeWarningsNotFailures() throws {
        let reply = #"{"name": "", "exercises": [{"exercise": "Curl", "primary_muscle": "guns", "sets": 50, "reps": 12}]}"#
        let (program, warnings) = try CoachProgramParser.parse(reply)
        XCTAssertEqual(program.name, "Coach program")
        XCTAssertNil(program.lines[0].primaryMuscle)
        XCTAssertNil(program.lines[0].targetSets)
        XCTAssertEqual(program.lines[0].targetReps, 12)
        XCTAssertEqual(warnings.count, 2)
    }

    func testRepliesWithoutAProgramAreRejected() {
        XCTAssertThrowsError(try CoachProgramParser.parse("Sorry, I can't help with that.")) {
            XCTAssertEqual($0 as? CoachProgramParser.ParseError, .noJSON)
        }
        XCTAssertThrowsError(try CoachProgramParser.parse(#"{"name": "x", "exercises": [{"exercise": "  "}]}"#)) {
            XCTAssertEqual($0 as? CoachProgramParser.ParseError, .empty)
        }
        XCTAssertThrowsError(try CoachProgramParser.parse(#"{"exercises": "squats"}"#)) {
            XCTAssertEqual($0 as? CoachProgramParser.ParseError, .badShape)
        }
    }

    func testPromptOffersEveryStoredMuscleName() {
        for muscle in LiftMuscle.allCases {
            XCTAssertTrue(CoachProgramParser.systemPrompt.contains(muscle.rawValue), muscle.rawValue)
        }
    }
}
