import Foundation

// nikhil/custom — starting a Lift Log session on the phone also starts a strength workout in the NOOP
// Watch app (watch sensors → Apple Health + Activity rings), while the strap keeps feeding the Lift Log.
// Shared by the phone (sender) and the watch (receiver); project.yml adds this file to NOOPWatch.
enum LiftWatchWorkout {
    /// WatchConnectivity key, phone → watch: end the running workout. Value: Bool, true = save it to
    /// Health (Lift Log saved), false = discard it (Lift Log discarded).
    static let endMessageKey = "custom.lift.endWorkout"
    /// When the end request was sent (epoch seconds), so a queued request can't end a later workout.
    static let sentAtKey = "custom.lift.endWorkout.sentAt"

    /// True when two intervals overlap by more than half of the shorter one, the same "same session" test
    /// NOOP's own cross-source workout dedup uses.
    static func overlapsMostly(_ aStart: Int, _ aEnd: Int, _ bStart: Int, _ bEnd: Int) -> Bool {
        let overlap = min(aEnd, bEnd) - max(aStart, bStart)
        guard overlap > 0 else { return false }
        let shorter = max(1, min(aEnd - aStart, bEnd - bStart))
        return Double(overlap) > 0.5 * Double(shorter)
    }
}

// MARK: - Watch Lift Log screen

/// What the watch's Lift Log screen shows: the set in focus (the one being worked, else the one coming
/// up), its numbers prefilled from the phone (typed, else grey), and where the session is. Sent phone →
/// watch whenever the session changes; `nil`-active means no session.
struct LiftWatchState: Codable, Equatable {
    enum Stage: String, Codable { case warmup, working, resting, finished }

    var stage: Stage
    var exercise: String
    var exerciseIndex: Int        // 0-based, the focus slot's
    var exerciseCount: Int
    var setIndex: Int             // 1-based within the exercise
    var setCount: Int
    var weightKg: Double?
    var reps: Int?
    var restEndsAt: Int?          // unix seconds, while resting
    var completedSets: Int
    var plannedSets: Int
    var imperial: Bool

    /// The step the crown moves weight by, in the display unit.
    var weightStep: Double { imperial ? 5 : 2.5 }

    static let messageKey = "custom.lift.state"
    /// Value of `messageKey` when no session is running.
    static let noSession = Data()

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    static func decode(_ data: Data) -> LiftWatchState? { try? JSONDecoder().decode(LiftWatchState.self, from: data) }
}

/// Watch → phone: the big button on the watch's Lift Log screen, with the numbers shown for the set.
struct LiftWatchAction: Codable, Equatable {
    var exerciseIndex: Int
    var setIndex: Int
    var weightKg: Double?
    var reps: Int?

    static let messageKey = "custom.lift.action"
    /// Watch → phone: "send me the current state" (screen appeared / app relaunched).
    static let requestKey = "custom.lift.requestState"

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    static func decode(_ data: Data) -> LiftWatchAction? { try? JSONDecoder().decode(LiftWatchAction.self, from: data) }
}
