import Foundation

// nikhil/custom — the hydration state the phone pushes to the watch, plus the pacing math the phone's
// reminders, the watch's Water page and the water complication all share.
//
// The day splits into a STANDARD amount (the morning water, the coffee: drunk every day, counted
// automatically, never tapped in) and the TRACKED rest of the goal. The tracked part is paced evenly over
// a window of hours: at each hour boundary inside the window you should have logged that many hours'
// share. Falling short at a boundary is what a reminder buzzes for.
//
// Lives in StrandDesign (like `WatchScoreSnapshot`) because the watch app and the complication extension
// only link this package.
public struct WatchHydrationSnapshot: Codable, Equatable, Sendable {
    /// The local day ("yyyy-MM-dd") the totals describe.
    public var day: String
    /// Everything counted for the day (ml): the standard amount once applied, taps, and Apple Health water.
    public var totalML: Int
    /// The standard daily amount (ml) from the plan.
    public var standardML: Int
    /// Whether the standard amount is part of `totalML` for `day` (the user can remove it for a day).
    public var standardApplied: Bool
    public var goalML: Int
    /// One tap's worth (ml): the complication, the watch button and the reminder action all log this.
    public var glassML: Int
    /// The pacing window, whole local hours, end exclusive of nothing after it (e.g. 11 and 21).
    public var windowStartHour: Int
    public var windowEndHour: Int
    public var asOf: Date

    public init(day: String, totalML: Int, standardML: Int, standardApplied: Bool, goalML: Int, glassML: Int,
                windowStartHour: Int, windowEndHour: Int, asOf: Date = Date()) {
        self.day = day
        self.totalML = totalML
        self.standardML = standardML
        self.standardApplied = standardApplied
        self.goalML = goalML
        self.glassML = glassML
        self.windowStartHour = windowStartHour
        self.windowEndHour = windowEndHour
        self.asOf = asOf
    }

    // MARK: Derived

    /// The part of the goal that gets tapped in.
    public var trackedTargetML: Int { HydrationPace.trackedTarget(goalML: goalML, standardML: standardML) }
    /// What has been tapped in (or imported) towards the tracked target.
    public var trackedML: Int { max(0, totalML - (standardApplied ? standardML : 0)) }
    public var remainingML: Int { max(0, goalML - totalML) }
    public var fraction: Double { goalML > 0 ? min(1, max(0, Double(totalML) / Double(goalML))) : 0 }

    /// How far behind the hourly pace the tracked amount is at `now` (0 when on pace or outside the window).
    public func behindML(now: Date = Date(), calendar: Calendar = .current) -> Int {
        let expected = HydrationPace.expectedML(trackedTargetML: trackedTargetML, startHour: windowStartHour,
                                                endHour: windowEndHour, at: now, calendar: calendar)
        return max(0, expected - trackedML)
    }

    /// This snapshot as it should read at `now`: once the day has rolled over and the phone hasn't said
    /// anything yet, a fresh day holds only the standard amount.
    public func current(now: Date = Date()) -> WatchHydrationSnapshot {
        let today = Self.dayKey(now)
        guard day != today else { return self }
        var next = self
        next.day = today
        next.totalML = standardML
        next.standardApplied = standardML > 0
        return next
    }

    /// The day after a tap of `ml` (or an undo, negative), applied locally before the phone confirms.
    public func adding(_ ml: Int, now: Date = Date()) -> WatchHydrationSnapshot {
        var next = current(now: now)
        next.totalML = max(0, next.totalML + ml)
        next.asOf = now
        return next
    }

    /// "yyyy-MM-dd" in the local calendar, the same key the phone's store uses.
    public static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: Transport

    /// Application-context key the encoded snapshot rides under (next to the score snapshot).
    public static let contextKey = "hydration"
    /// Watch → phone: log `glassML` ml. Payload `[logMessageKey: Int ml, entryIdKey: String uuid]`.
    public static let logMessageKey = "hydration.log"
    /// Watch → phone: remove the entry logged with this id. Payload `[undoMessageKey: String uuid]`.
    public static let undoMessageKey = "hydration.undo"
    public static let entryIdKey = "hydration.id"
    /// Watch → phone: take `ml` off today's tracked drinks, newest first. Payload `[removeMessageKey: Int ml]`.
    public static let removeMessageKey = "hydration.remove"

    /// App-group key the latest snapshot is stored under, read by the watch app and the complication.
    public static let storageKey = "latestWatchHydration"

    public static func load(from defaults: UserDefaults? = UserDefaults(suiteName: WatchScoreSnapshot.appGroupId))
        -> WatchHydrationSnapshot? {
        guard let data = defaults?.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(WatchHydrationSnapshot.self, from: data)
    }

    public func save(to defaults: UserDefaults? = UserDefaults(suiteName: WatchScoreSnapshot.appGroupId)) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults?.set(data, forKey: Self.storageKey)
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
    public static func decode(_ data: Data?) -> WatchHydrationSnapshot? {
        data.flatMap { try? JSONDecoder().decode(WatchHydrationSnapshot.self, from: $0) }
    }
}

/// The hourly pacing of the tracked amount. Pure, so the reminders and the watch agree and it is testable.
public enum HydrationPace {
    public static func trackedTarget(goalML: Int, standardML: Int) -> Int { max(0, goalML - max(0, standardML)) }

    /// A usable window: hours clamped to 0...24 with the end after the start (a bad pair becomes 9–21).
    public static func window(startHour: Int, endHour: Int) -> (start: Int, end: Int) {
        let s = min(max(startHour, 0), 23), e = min(max(endHour, 1), 24)
        return e > s ? (s, e) : (9, 21)
    }

    /// What should be tracked by the top of `hour`: an even share for each whole hour since the start.
    public static func expectedML(trackedTargetML: Int, startHour: Int, endHour: Int, byHour hour: Int) -> Int {
        let w = window(startHour: startHour, endHour: endHour)
        let done = min(max(hour - w.start, 0), w.end - w.start)
        return Int((Double(trackedTargetML) * Double(done) / Double(w.end - w.start)).rounded())
    }

    /// What should be tracked at `date` (counting only completed hours of the window).
    public static func expectedML(trackedTargetML: Int, startHour: Int, endHour: Int, at date: Date,
                                  calendar: Calendar = .current) -> Int {
        expectedML(trackedTargetML: trackedTargetML, startHour: startHour, endHour: endHour,
                   byHour: calendar.component(.hour, from: date))
    }

    /// The hour boundaries a reminder checks: each top of the hour after the window opens, through its end.
    public static func checkHours(startHour: Int, endHour: Int) -> [Int] {
        let w = window(startHour: startHour, endHour: endHour)
        return Array((w.start + 1)...w.end)
    }

    /// Of `checkHours`, the ones where `trackedML` falls short of the pace, i.e. the reminders still due if
    /// nothing more is logged. A log that gets ahead of pace drops every boundary it already covers.
    public static func dueHours(trackedML: Int, trackedTargetML: Int, startHour: Int, endHour: Int) -> [Int] {
        guard trackedTargetML > 0 else { return [] }
        return checkHours(startHour: startHour, endHour: endHour).filter {
            expectedML(trackedTargetML: trackedTargetML, startHour: startHour, endHour: endHour, byHour: $0) > trackedML
        }
    }
}
