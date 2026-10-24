import Foundation

// nikhil/custom — one-tap interval timer presets, shared by the phone/Mac timer and the watch timer
// (project.yml adds this file to the NOOPWatch target). Pure values, no UI.

struct IntervalPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let workSeconds: Int
    let restSeconds: Int
    let rounds: Int

    /// "4:00 / 3:00 × 6"
    var summary: String {
        "\(Self.clock(workSeconds)) / \(Self.clock(restSeconds)) × \(rounds)"
    }

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

    /// One-tap buttons on the phone/Mac timer.
    static let quick = [hiit, sprints]
    /// Choices on the watch timer.
    static let watch = [classic, hiit, sprints]

    /// The 3-2-1 countdown ticks only make sense on phases long enough to need a warning; on a
    /// ≤10 s phase they would buzz nearly every second and drown out the work/rest cues.
    static func countdownTicks(phaseSeconds: Int) -> Bool { phaseSeconds > 10 }
}
