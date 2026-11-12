import SwiftUI
import StrandDesign
import WhoopStore

// nikhil/custom — the day's macro targets, drawn as rings on the Nutrition screen and handed to the
// "What should I eat?" advice. Each macro is a floor (eat at least), a cap (stay under) or an aim (land
// near it). The defaults are Nikhil's, from the HealthVault: ≥140 g protein for the recomp, saturated fat
// ≤13 g for the heart, fibre ~35 g, and carbs and unsaturated fat sized to fill a ~1,600 kcal day.
// All six change in Targets and burn.

enum NutritionMacro: String, CaseIterable, Identifiable {
    case protein, fiber, carbs, sugar, unsatFat, satFat

    var id: String { rawValue }

    enum Kind { case floor, cap, aim }

    var kind: Kind {
        switch self {
        case .protein, .fiber, .unsatFat: return .floor
        case .sugar, .satFat: return .cap
        case .carbs: return .aim
        }
    }

    var title: String {
        switch self {
        case .protein: return String(localized: "Protein")
        case .fiber: return String(localized: "Fibre")
        case .carbs: return String(localized: "Carbs")
        case .sugar: return String(localized: "Sugar")
        case .unsatFat: return String(localized: "Unsat fat")
        case .satFat: return String(localized: "Sat fat")
        }
    }

    /// The word before the target: "min 140", "max 13", "aim 140".
    var kindWord: String {
        switch kind {
        case .floor: return String(localized: "min")
        case .cap: return String(localized: "max")
        case .aim: return String(localized: "aim")
        }
    }

    var defaultGrams: Int {
        switch self {
        case .protein: return 140
        case .fiber: return 35
        case .carbs: return 140
        case .sugar: return 50
        case .unsatFat: return 35
        case .satFat: return 13
        }
    }

    var range: ClosedRange<Int> {
        switch self {
        case .protein: return 30...300
        case .fiber: return 10...80
        case .carbs: return 20...500
        case .sugar: return 5...200
        case .unsatFat: return 5...150
        case .satFat: return 3...60
        }
    }

    var step: Int { self == .fiber || self == .satFat ? 1 : 5 }

    var key: String { "noop.nutritionTarget.\(rawValue)" }

    var target: Int {
        let d = UserDefaults.standard
        let v = d.object(forKey: key) == nil ? defaultGrams : d.integer(forKey: key)
        return min(max(v, range.lowerBound), range.upperBound)
    }

    /// This macro's grams in `m`. Unsaturated fat is total fat less saturated.
    func grams(_ m: NutritionMacros) -> Double {
        switch self {
        case .protein: return m.proteinG
        case .fiber: return m.fiberG
        case .carbs: return m.carbsG
        case .sugar: return m.sugarG
        case .unsatFat: return max(0, m.fatG - m.satFatG)
        case .satFat: return m.satFatG
        }
    }

    enum Status: Equatable {
        /// Not there yet (a floor or an aim still filling).
        case short
        /// A floor reached, an aim landed, or a cap comfortably under.
        case good
        /// Close to a cap, or an aim overshot a little.
        case near
        /// Past a cap, or an aim overshot a lot.
        case over

        var color: Color {
            switch self {
            case .short: return StrandPalette.accent
            case .good: return StrandPalette.statusPositive
            case .near: return StrandPalette.statusWarning
            case .over: return StrandPalette.statusCritical
            }
        }
    }

    /// Floors are good once reached. Caps are good below 85 %, near up to the cap, over past it. Aims are
    /// good within −10 % … +15 %, near to +30 %, over beyond.
    func status(_ grams: Double, target: Double) -> Status {
        let t = max(target, 0.1)
        switch kind {
        case .floor: return grams >= t ? .good : .short
        case .cap: return grams > t ? .over : (grams >= 0.85 * t ? .near : .good)
        case .aim:
            if grams < 0.9 * t { return .short }
            if grams <= 1.15 * t { return .good }
            return grams <= 1.3 * t ? .near : .over
        }
    }

    /// The day's macros: each row's recipe × its portion.
    static func totals(_ items: [NutritionItem], recipes: [String: NutritionRecipe]) -> NutritionMacros {
        NutritionMacros.sum(items.compactMap { recipes[$0.recipeId]?.macros.scaled($0.portion) })
    }
}
