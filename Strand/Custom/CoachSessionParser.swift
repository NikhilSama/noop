import Foundation
import WhoopStore

// nikhil/custom — "Log what you did" for a recorded strength workout: the prompt that asks the Coach's model
// to turn a typed or spoken account of a FINISHED session into the sets actually performed, and the parser
// for its JSON reply. The twin of `CoachProgramParser`, which builds a plan to run later; this one records
// what already happened, so every set carries its own reps and weight. Pure, so it is unit-tested without
// a model.

/// A finished session as described: exercises in the order done, each with its sets.
struct LoggedSession: Equatable {
    var name: String
    var note: String?
    var exercises: [LoggedExercise]
}

struct LoggedExercise: Equatable {
    var exercise: String
    var primaryMuscle: LiftMuscle?
    var secondaryMuscles: [LiftMuscle]
    var sets: [LoggedSet]
}

struct LoggedSet: Equatable {
    var weightKg: Double?
    var reps: Int?
    var isWarmup: Bool = false
}

enum CoachSessionParser {

    /// Sets per exercise past which a reply is taken to be a mistake and trimmed.
    static let maxSetsPerExercise = 20

    /// The system prompt. Muscle names are the stored raw values, so the reply maps without a lookup table.
    static let systemPrompt: String = """
    You turn a person's account of a strength-training session they have ALREADY FINISHED into the list of \
    sets they actually performed, for a lift log. The account may be typed or transcribed from speech, so \
    expect filler words, numbers spoken as words, and corrections ("no, it was twelve reps").

    Reply with ONE JSON object and nothing else: no prose, no code fences. Shape:
    {"name": string, "note": string or null, "exercises": [{"exercise": string, \
    "primary_muscle": string or null, "secondary_muscles": [string], "weight_unit": "kg" or "lb" or null, \
    "sets": [{"reps": integer or null, "weight": number or null, "warmup": boolean}]}]}

    Rules:
    - Keep the exercises in the order described. One entry per exercise; if they came back to an exercise \
    later, give it a second entry at that point.
    - Use a short, conventional exercise name ("Back squat", "Romanian deadlift", "Lat pulldown").
    - One object in "sets" per set performed. Expand shorthand: "3 sets of 10 at 20" is three sets of 10 \
    reps at 20; "10, 8, 6 at 60" is three sets at 60 with 10, 8 and 6 reps; "3 by 12, last one only 9" is \
    12, 12, 9.
    - weight is per set as spoken; weight_unit is the unit they used (null if they gave none). Bodyweight \
    or no weight given: weight null. Never invent weights or reps; leave a value null rather than guess.
    - warmup is true only for sets they call a warm-up.
    - primary_muscle and secondary_muscles must come from this list, or be null / empty: \
    \(LiftMuscle.allCases.map(\.rawValue).joined(separator: ", ")). Pick the main muscle the exercise \
    trains as primary_muscle and the other muscles it clearly works as secondary_muscles.
    - name: a short session name from what they said (for example "Leg day"), else "Strength session".
    - note: anything else they said about the session as a whole (how it felt, a niggle), else null.
    """

    /// The session plus anything worth checking (unknown muscles, values out of range that were dropped).
    static func parse(_ reply: String) throws -> (session: LoggedSession, warnings: [String]) {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8) else { throw CoachProgramParser.ParseError.noJSON }
        let raw: RawSession
        do { raw = try JSONDecoder().decode(RawSession.self, from: data) } catch {
            throw CoachProgramParser.ParseError.badShape
        }

        var warnings: [String] = []
        var exercises: [LoggedExercise] = []
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
            let pounds = e.weightUnit?.lowercased() == "lb"
            var sets: [LoggedSet] = (e.sets ?? []).map { s in
                let kg = s.weight.map { pounds ? $0 / 2.2046226218 : $0 }
                return LoggedSet(weightKg: inRange(kg.map { ($0 * 10).rounded() / 10 }, 0, 600, "weight"),
                                 reps: inRange(s.reps, 1, 100, "reps"),
                                 isWarmup: s.warmup ?? false)
            }
            if sets.count > maxSetsPerExercise {
                warnings.append("Line \(i + 1) (\(name)): \(sets.count) sets looks wrong; kept the first \(maxSetsPerExercise).")
                sets = Array(sets.prefix(maxSetsPerExercise))
            }
            // An exercise named with no sets still happened: one blank set to fill in, not a dropped line.
            if sets.isEmpty { sets = [LoggedSet()] }
            let primary = muscle(e.primaryMuscle)
            exercises.append(LoggedExercise(
                exercise: name,
                primaryMuscle: primary,
                secondaryMuscles: (e.secondaryMuscles ?? []).compactMap(muscle).filter { $0 != primary },
                sets: sets))
        }
        guard !exercises.isEmpty else { throw CoachProgramParser.ParseError.empty }
        let name = (raw.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (LoggedSession(name: name.isEmpty ? "Strength session" : name,
                              note: raw.note.flatMap { $0.isEmpty ? nil : $0 },
                              exercises: exercises),
                warnings)
    }

    private struct RawSession: Decodable {
        let name: String?
        let note: String?
        let exercises: [RawExercise]?
    }

    private struct RawExercise: Decodable {
        let exercise: String?
        let primaryMuscle: String?
        let secondaryMuscles: [String]?
        let weightUnit: String?
        let sets: [RawSet]?

        enum CodingKeys: String, CodingKey {
            case exercise, sets
            case primaryMuscle = "primary_muscle"
            case secondaryMuscles = "secondary_muscles"
            case weightUnit = "weight_unit"
        }
    }

    private struct RawSet: Decodable {
        let repsValue: CoachProgramParser.Flex?
        let weightValue: CoachProgramParser.Flex?
        let warmup: Bool?

        var reps: Int? { repsValue?.int }
        var weight: Double? { weightValue?.value }

        enum CodingKeys: String, CodingKey {
            case repsValue = "reps", weightValue = "weight", warmup
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            repsValue = try? c.decodeIfPresent(CoachProgramParser.Flex.self, forKey: .repsValue)
            weightValue = try? c.decodeIfPresent(CoachProgramParser.Flex.self, forKey: .weightValue)
            warmup = try? c.decodeIfPresent(Bool.self, forKey: .warmup)
        }
    }
}

/// The user's own exercise list wins over the model's guess: an exercise already in it keeps its spelling
/// (so "last time" history lines up) and the muscles the user gave it.
enum CoachVocabulary {
    struct Known: Equatable {
        let name: String
        let primaryMuscle: LiftMuscle?
        let secondaryMuscles: [LiftMuscle]
    }

    static func lookup(_ name: String, in rows: [LiftExerciseRow]) -> Known? {
        let key = normalised(name)
        guard !key.isEmpty, let row = rows.first(where: { normalised($0.name) == key }) else { return nil }
        return Known(name: row.name, primaryMuscle: row.primaryMuscle, secondaryMuscles: row.secondaryMuscles)
    }

    private static func normalised(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "-" }).joined(separator: " ")
    }
}
