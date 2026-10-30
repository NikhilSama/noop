import Foundation
import StrandImport
import WhoopStore

// nikhil/custom — "Import with Coach" for the Lift Log: the prompt that asks the Coach's model to turn a
// typed or spoken workout description into a program, and the parser that turns its JSON reply into the
// same `ImportedProgram` the spreadsheet import produces. Pure, so it is unit-tested without a model.

enum CoachProgramParser {

    enum ParseError: Error, Equatable {
        /// The reply held no JSON object at all.
        case noJSON
        /// JSON, but not the shape asked for.
        case badShape
        /// The right shape with no exercises in it.
        case empty
    }

    /// The system prompt. Muscle names are the stored raw values, so the reply maps without a lookup table.
    static let systemPrompt: String = """
    You turn a person's description of a strength-training workout into a structured program for a lift \
    log. The description may be typed or transcribed from speech, so expect filler words, numbers spoken \
    as words, and corrections ("no, make that four sets").

    Reply with ONE JSON object and nothing else: no prose, no code fences. Shape:
    {"name": string, "note": string or null, "exercises": [{"exercise": string, \
    "primary_muscle": string or null, "secondary_muscles": [string], "sets": integer or null, \
    "reps": integer or null, "weight": number or null, "weight_unit": "kg" or "lb" or null, \
    "rest_sec": integer or null, "max_rpe": number or null, "note": string or null}]}

    Rules:
    - Keep the exercises in the order described. One entry per exercise.
    - Use a short, conventional exercise name ("Back squat", "Romanian deadlift", "Lat pulldown").
    - Fill a field only when the person said it or it follows directly from what they said. Leave it \
    null rather than guessing. Never invent weights.
    - weight is per set as spoken; weight_unit is the unit they used (null if they gave none).
    - rest_sec is the rest between sets in seconds ("two minutes" is 120).
    - max_rpe is a 1-10 effort ceiling, only if they mention RPE or effort.
    - primary_muscle and secondary_muscles must come from this list, or be null / empty: \
    \(LiftMuscle.allCases.map(\.rawValue).joined(separator: ", ")). Pick the main muscle the exercise \
    trains as primary_muscle.
    - name: a short program name from what they said (for example "Leg day"), else "Coach program".
    - note: a technique cue or tempo they mentioned for the whole program, else null.
    """

    /// The program plus anything worth checking (unknown muscles, values out of range that were dropped).
    static func parse(_ reply: String) throws -> (program: ImportedProgram, warnings: [String]) {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8) else { throw ParseError.noJSON }
        let raw: RawProgram
        do { raw = try JSONDecoder().decode(RawProgram.self, from: data) } catch { throw ParseError.badShape }

        var warnings: [String] = []
        var lines: [ImportedProgramLine] = []
        for (i, e) in (raw.exercises ?? []).enumerated() {
            let name = (e.exercise ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            func muscle(_ s: String?) -> LiftMuscle? {
                guard let s, !s.isEmpty else { return nil }
                if let m = LiftMuscle(rawValue: s) { return m }
                warnings.append("Line \(i + 1) (\(name)): \"\(s)\" is not a muscle the log knows; left unclassified.")
                return nil
            }
            func inRange<T: Comparable>(_ v: T?, _ lo: T, _ hi: T, _ what: String) -> T? {
                guard let v else { return nil }
                if v < lo || v > hi {
                    warnings.append("Line \(i + 1) (\(name)): \(what) \(v) looks wrong; left blank.")
                    return nil
                }
                return v
            }
            let kg: Double? = e.weight.map { e.weightUnit?.lowercased() == "lb" ? $0 / 2.2046226218 : $0 }
            lines.append(ImportedProgramLine(
                exercise: name,
                primaryMuscle: muscle(e.primaryMuscle),
                secondaryMuscles: (e.secondaryMuscles ?? []).compactMap(muscle),
                targetSets: inRange(e.sets, 1, 20, "sets"),
                targetReps: inRange(e.reps, 1, 100, "reps"),
                targetWeightKg: inRange(kg.map { ($0 * 10).rounded() / 10 }, 0, 600, "weight"),
                targetMaxRpe: inRange(e.maxRpe, 1, 10, "RPE"),
                restSec: inRange(e.restSec, 0, 900, "rest"),
                note: e.note.flatMap { $0.isEmpty ? nil : $0 }))
        }
        guard !lines.isEmpty else { throw ParseError.empty }
        let name = (raw.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (ImportedProgram(name: name.isEmpty ? "Coach program" : name,
                                note: raw.note.flatMap { $0.isEmpty ? nil : $0 },
                                lines: lines),
                warnings)
    }

    private struct RawProgram: Decodable {
        let name: String?
        let note: String?
        let exercises: [RawLine]?
    }

    private struct RawLine: Decodable {
        let exercise: String?
        let primaryMuscle: String?
        let secondaryMuscles: [String]?
        let setsValue: Flex?
        let repsValue: Flex?
        let weightValue: Flex?
        let weightUnit: String?
        let restValue: Flex?
        let rpeValue: Flex?
        let note: String?

        var sets: Int? { setsValue?.int }
        var reps: Int? { repsValue?.int }
        var weight: Double? { weightValue?.value }
        var restSec: Int? { restValue?.int }
        var maxRpe: Double? { rpeValue?.value }

        enum CodingKeys: String, CodingKey {
            case exercise, note
            case setsValue = "sets", repsValue = "reps", weightValue = "weight"
            case primaryMuscle = "primary_muscle"
            case secondaryMuscles = "secondary_muscles"
            case weightUnit = "weight_unit"
            case restValue = "rest_sec"
            case rpeValue = "max_rpe"
        }
    }

    /// A number the model may send as 3, 3.0 or "3". Anything else decodes as nil, not a failure.
    private struct Flex: Decodable {
        let value: Double?
        var int: Int? { value.map { Int($0.rounded()) } }

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { value = d }
            else if let s = try? c.decode(String.self) {
                value = Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
            } else { value = nil }
        }
    }
}
