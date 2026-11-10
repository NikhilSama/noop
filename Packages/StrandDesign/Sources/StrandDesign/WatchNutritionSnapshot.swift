import Foundation
import SwiftUI

// nikhil/custom — the day's food balance the phone pushes to the watch, and the colour bands the phone's
// Nutrition card and the watch complication share.
//
// "Off plan" is in + planned deficit − out: 0 means the day is landing exactly on the deficit target,
// positive is eating more (or burning less) than the plan, negative is undereating against it.
//
// Lives in StrandDesign (like `WatchHydrationSnapshot`) because the watch app and the complication
// extension only link this package.

/// How far a day is from its plan: green within ±100 kcal, yellow out to the size of the target (for a
/// −300 target that's still a deficit, just not the planned one), red past it (a real surplus, or eating
/// far too little).
public enum NutritionBand: String, Codable, Sendable {
    case onPlan, near, off

    public static let onPlanKcal = 100.0

    public static func of(offPlan: Double, target: Double) -> NutritionBand {
        let a = abs(offPlan)
        if a <= onPlanKcal { return .onPlan }
        return a <= yellowLimit(target: target) ? .near : .off
    }

    /// Where yellow ends: the size of the target, never inside the green band.
    public static func yellowLimit(target: Double) -> Double { max(abs(target), onPlanKcal) }

    public var color: Color {
        switch self {
        case .onPlan: return StrandPalette.statusPositive
        case .near: return StrandPalette.statusWarning
        case .off: return StrandPalette.statusCritical
        }
    }
}

public struct WatchNutritionSnapshot: Codable, Equatable, Sendable {
    /// The local day ("yyyy-MM-dd") the numbers describe.
    public var day: String
    /// in + planned deficit − out, kcal.
    public var offPlanKcal: Int
    /// The plan's balance target (in − out), so a deficit is negative.
    public var targetKcal: Int
    public var inKcal: Int
    public var outKcal: Int
    public var asOf: Date

    public init(day: String, offPlanKcal: Int, targetKcal: Int, inKcal: Int, outKcal: Int, asOf: Date = Date()) {
        self.day = day
        self.offPlanKcal = offPlanKcal
        self.targetKcal = targetKcal
        self.inKcal = inKcal
        self.outKcal = outKcal
        self.asOf = asOf
    }

    public var band: NutritionBand { .of(offPlan: Double(offPlanKcal), target: Double(targetKcal)) }
    /// Half the meter's width: twice the yellow limit, so green, yellow and red each get room.
    public var meterRange: Double { NutritionBand.yellowLimit(target: Double(targetKcal)) * 2 }

    /// Nil once the day has rolled over: yesterday's balance says nothing about today.
    public func current(now: Date = Date()) -> WatchNutritionSnapshot? {
        day == WatchHydrationSnapshot.dayKey(now) ? self : nil
    }

    // MARK: Transport

    /// Whether `next` is worth a complication transfer (a ~50/day budget shared with the water and the
    /// scores): a new day or colour band always is; otherwise a move of 40+ kcal, 30+ minutes after the last.
    public static func transferDue(last: (snap: WatchNutritionSnapshot, at: Date)?, next: WatchNutritionSnapshot,
                                   now: Date) -> Bool {
        guard let last else { return true }
        if last.snap.day != next.day || last.snap.band != next.band { return true }
        return abs(last.snap.offPlanKcal - next.offPlanKcal) >= 40 && now.timeIntervalSince(last.at) >= 30 * 60
    }

    /// Application-context key the encoded snapshot rides under (next to the scores and the water).
    public static let contextKey = "nutrition"
    /// App-group key the latest snapshot is stored under, read by the complication.
    public static let storageKey = "latestWatchNutrition"

    public static func load(from defaults: UserDefaults? = UserDefaults(suiteName: WatchScoreSnapshot.appGroupId))
        -> WatchNutritionSnapshot? {
        decode(defaults?.data(forKey: storageKey))
    }

    public func save(to defaults: UserDefaults? = UserDefaults(suiteName: WatchScoreSnapshot.appGroupId)) {
        guard let data = encoded() else { return }
        defaults?.set(data, forKey: Self.storageKey)
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
    public static func decode(_ data: Data?) -> WatchNutritionSnapshot? {
        data.flatMap { try? JSONDecoder().decode(WatchNutritionSnapshot.self, from: $0) }
    }
}
