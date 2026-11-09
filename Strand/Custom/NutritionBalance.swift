import Foundation
import WhoopStore

// nikhil/custom — calories in vs calories out for one day, as the Today card draws it.
//
// IN is the whole planned day (the standard rows, plus extras, less anything removed) — it does not grow
// with the clock. OUT is the resting burn for the whole day, digestion (TEF, a share of what is planned) and
// the active energy recorded SO FAR, so the balance is "where the day lands if nothing more is burned".
// Active is the average of the two measurements when both exist: Apple active energy, and the strap's
// whole-day energy less the resting burn accrued over the same span. Same rule as the vault's TDEE-method,
// which averages "Apple active + RMR + TEF" with "strap day energy + TEF".

enum NutritionPlan {
    static let rmrKey = "noop.nutritionRmrKcal"
    static let tefKey = "noop.nutritionTefPercent"
    static let targetKey = "noop.nutritionTargetBalance"

    static let defaultRmr = 1217
    static let defaultTef = 10
    /// Balance target (in − out), so a deficit is negative.
    static let defaultTarget = -300
    static let targetRange = -800...1000

    private static func int(_ key: String, _ fallback: Int) -> Int {
        UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.integer(forKey: key)
    }
    static var rmrKcal: Int { min(max(int(rmrKey, defaultRmr), 500), 4000) }
    static var tefPercent: Int { min(max(int(tefKey, defaultTef), 0), 25) }
    static var targetBalance: Int { min(max(int(targetKey, defaultTarget), targetRange.lowerBound), targetRange.upperBound) }
}

struct NutritionBalance: Equatable {
    /// Rows that came from the standard day (swapped or resized ones included).
    var standardKcal: Double
    /// Rows added on the day.
    var extraKcal: Double
    /// The full standard day for this date, for the faint tick when rows were removed or shrunk.
    var fullStandardKcal: Double
    var rmrKcal: Double
    var tefKcal: Double
    var activeKcal: Double
    /// in − out; negative is a deficit.
    var targetBalance: Double

    var inKcal: Double { standardKcal + extraKcal }
    var outKcal: Double { rmrKcal + tefKcal + activeKcal }
    var balance: Double { inKcal - outKcal }
    var hit: Bool { balance <= targetBalance }
    /// How much more to burn (or not eat) to reach the target; 0 once hit.
    var toGo: Double { max(0, balance - targetBalance) }
    /// How far past the target; 0 until hit.
    var spare: Double { max(0, targetBalance - balance) }

    /// Build a day's balance. `standardSlotIds` are the ids of the standard day in force (the day's own
    /// rows keep those ids when it is edited, so a swapped row still counts as standard).
    static func make(day: NutritionDay, standardSlots: [NutritionItem], recipes: [String: NutritionRecipe],
                     appleActiveKcal: Double?, strapDayKcal: Double?, dayFraction: Double,
                     rmr: Double = Double(NutritionPlan.rmrKcal), tefPercent: Double = Double(NutritionPlan.tefPercent),
                     target: Double = Double(NutritionPlan.targetBalance)) -> NutritionBalance {
        let ids = Set(standardSlots.map(\.id))
        func kcal(_ items: [NutritionItem]) -> Double {
            items.reduce(0) { $0 + (recipes[$1.recipeId]?.macros.kcal ?? 0) * $1.portion }
        }
        let standard = kcal(day.items.filter { ids.contains($0.id) })
        let extra = kcal(day.items.filter { !ids.contains($0.id) })
        return NutritionBalance(
            standardKcal: standard, extraKcal: extra, fullStandardKcal: kcal(standardSlots),
            rmrKcal: rmr, tefKcal: (standard + extra) * tefPercent / 100,
            activeKcal: active(apple: appleActiveKcal, strapDay: strapDayKcal, rmr: rmr, dayFraction: dayFraction),
            targetBalance: target)
    }

    /// The active energy so far: the average of Apple's and the strap's (whole-day energy less the resting
    /// burn accrued over `dayFraction` of the day), whichever exist.
    static func active(apple: Double?, strapDay: Double?, rmr: Double, dayFraction: Double) -> Double {
        let strap = strapDay.map { max(0, $0 - rmr * min(max(dayFraction, 0), 1)) }
        let values = [apple, strap].compactMap { $0 }
        return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    /// The planned row whose half portion best covers `need` kcal, for "or drop ½ kefir smoothie (−95)":
    /// the smallest half that covers it, else the biggest half there is.
    static func trimSuggestion(items: [NutritionItem], recipes: [String: NutritionRecipe], need: Double)
        -> (item: NutritionItem, name: String, saves: Double)? {
        let halves = items.compactMap { item -> (NutritionItem, String, Double)? in
            guard let r = recipes[item.recipeId], r.macros.kcal * item.portion >= 40 else { return nil }
            return (item, r.name, r.macros.kcal * item.portion / 2)
        }
        let covering = halves.filter { $0.2 >= need }.min { $0.2 < $1.2 }
        guard let pick = covering ?? halves.max(by: { $0.2 < $1.2 }) else { return nil }
        return (pick.0, pick.1, pick.2)
    }
}
