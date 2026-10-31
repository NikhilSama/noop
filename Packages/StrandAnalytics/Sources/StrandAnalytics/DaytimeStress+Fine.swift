import Foundation
import WhoopProtocol

// nikhil/custom: the minute-by-minute DISPLAY read of the daytime stress proxy.
//
// A trailing `fineWindowSeconds` window re-read every `fineStepSeconds` across the waking hours, so the
// line follows a tense call or a calm stretch instead of averaging it into the hour. Display-only, like
// `Result.timeline`: nothing that COUNTS hours (totals, sustained-high, high-stress minutes) reads it.
//
// HR-only on purpose. Daytime wrist RMSSD is already artifact-dominated at the hourly grain (see
// `daytimeRMSSDScoringEnabled`); over ten minutes posture and talking would own the line.
//
// Reference: in `.dayRelative` the hourly reference cannot be reused as-is — ten-minute means spread far
// wider than hourly ones, so the hourly across-hour SD would push ordinary minutes into HIGH. The SAME
// method is applied at this grain instead (calm lower quartile + spread of the day's own unmasked
// windows). `.baselineRelative` reuses its validated fixed-bpm margin, which is grain-independent.
//
// Motion gate at the window grain: a window that is ambulatory for `activityMaskFraction` of its records
// is masked, and so is a window whose HR is still `postActivityShadowBPM` above the calm reference within
// `fineShadowLookbackSeconds` of ambulatory motion (post-exertion recovery).
extension DaytimeStress {

    /// Trailing window each fine point scores (10 min).
    public static let fineWindowSeconds: Int = 600
    /// Spacing between fine points (1 min).
    public static let fineStepSeconds: Int = 60
    /// Minimum HR samples in a window before it is scored (~1 min at 1 Hz; the hourly gate's ratio).
    public static let minFineHRSamples: Int = 60
    /// How far back before a window ambulatory motion still casts a post-exertion shadow.
    public static let fineShadowLookbackSeconds: Int = 1_200

    /// `reference`: a fixed (calm HR, sd) to score against, or nil to derive it from the day's windows.
    static func fineTimeline(hr: [HRSample], activity: [WorkoutDetector.ActivityPoint],
                             tzOffsetSeconds: Int,
                             reference: (hr: Double, sd: Double)?) -> [HourPoint] {
        let hrs = hr.sorted { $0.ts < $1.ts }
        guard let firstTs = hrs.first?.ts, let lastTs = hrs.last?.ts else { return [] }
        let hrTs = hrs.map(\.ts)
        var hrPrefix = [0.0]; hrPrefix.reserveCapacity(hrs.count + 1)
        for s in hrs { hrPrefix.append(hrPrefix.last! + Double(s.bpm)) }

        let act = activity.sorted { $0.ts < $1.ts }
        let actTs = act.map(\.ts)
        var actPrefix = [0]; actPrefix.reserveCapacity(act.count + 1)
        for p in act { actPrefix.append(actPrefix.last! + (p.intensity > WorkoutDetector.motionThreshold ? 1 : 0)) }

        /// First index whose ts is >= t.
        func lowerBound(_ ts: [Int], _ t: Int) -> Int {
            var lo = 0, hi = ts.count
            while lo < hi { let m = (lo + hi) / 2; if ts[m] < t { lo = m + 1 } else { hi = m } }
            return lo
        }
        func ambulatory(_ from: Int, _ to: Int) -> Bool {
            let a = lowerBound(actTs, from), b = lowerBound(actTs, to)
            guard b > a else { return false }
            return Double(actPrefix[b] - actPrefix[a]) / Double(b - a) >= activityMaskFraction
        }

        struct Window { let end: Int; let meanHR: Double?; let active: Bool; let recentlyActive: Bool }
        let step = fineStepSeconds, w = fineWindowSeconds
        var windows: [Window] = []
        var end = (firstTs / step) * step + step
        while end <= lastTs + step {
            let localEnd = end + tzOffsetSeconds
            let hourOfDay = (floorDiv(localEnd - 1, bucketSeconds) % 24 + 24) % 24
            if hourOfDay >= wakingStartHour && hourOfDay < wakingEndHour {
                let a = lowerBound(hrTs, end - w), b = lowerBound(hrTs, end)
                let n = b - a
                let mean = n >= minFineHRSamples ? (hrPrefix[b] - hrPrefix[a]) / Double(n) : nil
                windows.append(Window(end: end, meanHR: mean,
                                      active: ambulatory(end - w, end),
                                      recentlyActive: ambulatory(end - w - fineShadowLookbackSeconds, end - w)))
            }
            end += step
        }

        let refHR: Double?, sdHR: Double
        if let reference {
            refHR = reference.hr; sdHR = reference.sd
        } else {
            let calm = windows.filter { !$0.active }.compactMap(\.meanHR)
            refHR = calmReference(calm, calmIsLow: true)
            sdHR = std(calm, mean: mean(calm))
        }

        return windows.map { win in
            let shadow = win.recentlyActive && win.meanHR != nil && refHR != nil
                && win.meanHR! > refHR! + postActivityShadowBPM
            let masked = win.meanHR != nil && (win.active || shadow)
            let level: Double? = (win.meanHR != nil && !masked)
                ? squash(rawScore(hr: win.meanHR, meanHR: refHR, sdHR: sdHR,
                                  rmssd: nil, meanRMSSD: nil, sdRMSSD: 0))
                : nil
            let localEnd = win.end + tzOffsetSeconds
            return HourPoint(hour: (floorDiv(localEnd - 1, bucketSeconds) % 24 + 24) % 24,
                             startTs: win.end - w, level: level, meanHR: win.meanHR, rmssd: nil,
                             maskedForActivity: masked)
        }
    }
}
