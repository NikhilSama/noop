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
