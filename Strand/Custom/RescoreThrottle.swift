import Foundation

// nikhil/custom — battery: how often the full 21-day re-score may run.
//
// Upstream re-scores the whole 21-day window after EVERY strap offload (every ~15 min) and again on a
// 30-minute backstop tick that cannot skip while live HR streams (the fingerprint moves every second):
// up to ~6 full passes an hour, all day, in the background. The window cannot simply shrink, because the
// Charge baselines are folded from that same window, so the pass is rate-limited instead:
// - a background post-offload pass runs only if the last pass is at least `postOffloadMinGap` old;
//   otherwise it is OWED, and the next backstop tick (≤30 min) pays it;
// - a foreground offload always re-scores immediately (the user is looking);
// - the backstop runs only when a pass is owed or the last one is older than `backstopMaxAge`.
enum RescoreThrottle {
    static let postOffloadMinGap: TimeInterval = 30 * 60
    static let backstopMaxAge: TimeInterval = 2 * 3600

    static func shouldRunPostOffload(lastPass: Date?, now: Date, foreground: Bool) -> Bool {
        guard !foreground, let lastPass else { return true }
        let age = now.timeIntervalSince(lastPass)
        return age < 0 || age >= postOffloadMinGap
    }

    static func shouldRunBackstop(lastPass: Date?, owed: Bool, now: Date) -> Bool {
        guard !owed, let lastPass else { return true }
        let age = now.timeIntervalSince(lastPass)
        return age < 0 || age >= backstopMaxAge
    }
}
