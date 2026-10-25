import Foundation

// nikhil/custom — one-tap interval timer presets, shared by the phone/Mac timer and the watch timer
// (project.yml adds this file to the NOOPWatch target). Pure values, no UI.

struct IntervalPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let workSeconds: Int
    let restSeconds: Int
    let rounds: Int
    /// Start with a rest block, so each round is rest → work and the session ends on the last work.
    var restFirst = false
    /// Counted transition cues instead of the strong/soft pair: ONE buzz when a rest ends, TWO when a
    /// work block ends, and no 3-2-1 ticks, so the count alone says which phase just finished.
    var countedCues = false

    /// "4:00 / 3:00 × 6", or "rest 0:30 → 0:30 × 10" for a rest-first preset.
    var summary: String {
        restFirst
            ? "rest \(Self.clock(restSeconds)) → \(Self.clock(workSeconds)) × \(rounds)"
            : "\(Self.clock(workSeconds)) / \(Self.clock(restSeconds)) × \(rounds)"
    }

    /// Total session length: every work block, plus a rest between rounds (and a leading one if rest-first).
    var totalSeconds: Int { rounds * workSeconds + (restFirst ? rounds : rounds - 1) * restSeconds }

    func matches(work: Int, rest: Int, rounds: Int) -> Bool {
        workSeconds == work && restSeconds == rest && self.rounds == rounds
    }

    static func clock(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
}

enum IntervalPresets {
    /// The original fixed timer (the watch's only option before presets).
    static let classic = IntervalPreset(id: "classic", name: "Classic", workSeconds: 30, restSeconds: 15, rounds: 8)
    static let hiit = IntervalPreset(id: "hiit", name: "HIIT", workSeconds: 240, restSeconds: 180, rounds: 6)
    static let sprints = IntervalPreset(id: "sprints", name: "Sprints", workSeconds: 6, restSeconds: 4, rounds: 20)
    /// 30 s rest → 30 s work, 10 rounds (20 blocks, 10:00). One buzz = rest over, two = work over.
    static let thirties = IntervalPreset(id: "thirties", name: "30/30", workSeconds: 30, restSeconds: 30, rounds: 10,
                                         restFirst: true, countedCues: true)

    /// One-tap buttons on the phone/Mac timer.
    static let quick = [hiit, sprints, thirties]
    /// Choices on the watch timer.
    static let watch = [classic, hiit, sprints, thirties]

    /// The 3-2-1 countdown ticks only make sense on phases long enough to need a warning; on a
    /// ≤10 s phase they would buzz nearly every second and drown out the work/rest cues.
    static func countdownTicks(phaseSeconds: Int) -> Bool { phaseSeconds > 10 }

    /// WatchConnectivity message key: the watch timer asks the phone to buzz the strap `n` loops
    /// (value: Int), so a session started on the wrist cues the WHOOP exactly like one started on the phone.
    static let strapBuzzMessageKey = "custom.interval.strapBuzz"
}
