import Foundation
import StrandAnalytics
import WhoopStore

// nikhil/custom — minutes in each HR zone per Mon–Sun week, from workouts, against weekly targets.
//
// A workout's zone minutes are always its recorded heart rate binned into the zones set in Profile (the same
// read the workout detail screen and the Workouts zones summary use); an imported WHOOP split is never used.
// Every workout counts, strength sessions included, unless the setting leaves strength out.
//
// Each zone's target is a weekly band in minutes (low…high), or none. The defaults are Nikhil's plan in the
// HealthVault: zone 2 about five sessions a week up to ~3 h (150–180 min), one VO2max interval session
// (zone 3, 15–30 min, since his zones put VT2 161 at the top of zone 3), and as little as possible above VT2
// (zone 4 up to 5 min, zone 5 none) for the heart. Zone 1 has no target.

enum CardioZones {
    struct Target: Equatable {
        var low: Int
        var high: Int
    }

    static let enabledKey = { (zone: Int) in "noop.cardioZoneTarget.z\(zone).on" }
    static let lowKey = { (zone: Int) in "noop.cardioZoneTarget.z\(zone).low" }
    static let highKey = { (zone: Int) in "noop.cardioZoneTarget.z\(zone).high" }
    static let includeStrengthKey = "noop.cardioZoneIncludeStrength"

    static let minutesRange = 0...1200

    /// The defaults for zones 1…5 (index 0 = zone 1).
    static let defaults: [Target?] = [nil, Target(low: 150, high: 180), Target(low: 15, high: 30),
                                      Target(low: 0, high: 5), Target(low: 0, high: 0)]

    static func target(_ zone: Int, defaults d: UserDefaults = .standard) -> Target? {
        guard (1...5).contains(zone) else { return nil }
        let fallback = defaults[zone - 1]
        let on = d.object(forKey: enabledKey(zone)) == nil ? fallback != nil : d.bool(forKey: enabledKey(zone))
        guard on else { return nil }
        func read(_ key: String, _ v: Int) -> Int {
            min(max(d.object(forKey: key) == nil ? v : d.integer(forKey: key), minutesRange.lowerBound), minutesRange.upperBound)
        }
        let low = read(lowKey(zone), fallback?.low ?? 0)
        return Target(low: low, high: max(low, read(highKey(zone), fallback?.high ?? low)))
    }

    static func save(_ zone: Int, _ target: Target?, defaults d: UserDefaults = .standard) {
        d.set(target != nil, forKey: enabledKey(zone))
        if let target {
            d.set(target.low, forKey: lowKey(zone))
            d.set(max(target.low, target.high), forKey: highKey(zone))
        }
    }

    static func resetTargets(defaults d: UserDefaults = .standard) {
        for z in 1...5 { [enabledKey(z), lowKey(z), highKey(z)].forEach { d.removeObject(forKey: $0) } }
    }

    /// On unless switched off.
    static var includeStrength: Bool {
        UserDefaults.standard.object(forKey: includeStrengthKey) == nil ? true : UserDefaults.standard.bool(forKey: includeStrengthKey)
    }

    /// Lifting, mobility and the like: their HR says little about cardio training.
    static func isStrength(_ sport: String) -> Bool {
        let s = sport.lowercased()
        return ["strength", "weight", "bodybuilding", "functional", "yoga", "pilates", "stretch", "mobility",
                "crossfit", "powerlifting", "calisthenics"].contains { s.contains($0) }
    }

    enum Status: Equatable { case none, short, good, near, over }

    /// Under the band is still filling; inside it is good; over by up to a quarter of the band's top (at
    /// least 5 min) is near; beyond that, over.
    static func status(_ minutes: Double, _ target: Target?) -> Status {
        guard let t = target else { return .none }
        let m = minutes.rounded()
        if m < Double(t.low) { return .short }
        if m <= Double(t.high) { return .good }
        return m <= Double(t.high) + max(5, 0.25 * Double(t.high)) ? .near : .over
    }

    struct Week: Identifiable, Equatable {
        /// The week's Monday, local midnight.
        var start: Date
        /// Zones 1…5.
        var minutes: [Double]
        var sessions: Int
        var id: Date { start }
        var total: Double { minutes.reduce(0, +) }
    }

    /// The last `count` Mon–Sun weeks ending with this one, oldest first, each with its workouts' zone
    /// minutes. Weeks with nothing are kept as zeros so the chart's axis is continuous.
    static func weeks(_ rows: [WorkoutRow], count: Int, now: Date = Date(), includeStrength: Bool,
                      calendar cal: Calendar = .current,
                      zoneMinutes: (WorkoutRow) async -> [Double]?) async -> [Week] {
        let thisMonday = NutritionHistory.monday(of: now, calendar: cal)
        let starts = (0..<max(count, 1)).reversed().compactMap { cal.date(byAdding: .day, value: -7 * $0, to: thisMonday) }
        guard let first = starts.first else { return [] }
        var out = starts.map { Week(start: $0, minutes: [0, 0, 0, 0, 0], sessions: 0) }
        for row in rows {
            let date = Date(timeIntervalSince1970: TimeInterval(row.startTs))
            guard date >= first, date <= now, includeStrength || !isStrength(row.sport) else { continue }
            let monday = NutritionHistory.monday(of: date, calendar: cal)
            guard let i = out.firstIndex(where: { $0.start == monday }),
                  let m = await zoneMinutes(row), m.count == 5 else { continue }
            for z in 0..<5 { out[i].minutes[z] += m[z] }
            out[i].sessions += 1
        }
        return out
    }
}

extension Repository {
    /// One workout's zone minutes (zones 1…5): its recorded HR in `zoneSet`, the Profile zones. Nil when
    /// the window has no HR. Imported WHOOP splits are ignored: they use WHOOP's zones, not these.
    func cardioZoneMinutes(_ row: WorkoutRow, zoneSet: HRZoneSet) async -> [Double]? {
        await workoutZoneMinutes(from: row.startTs, to: row.endTs, zoneSet: zoneSet, source: row.source)
    }
}
