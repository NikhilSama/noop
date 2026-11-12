import Foundation
import WhoopStore

// nikhil/custom — "What should I eat?": one request to the Coach's provider with the clock, the kcal left to
// land on today's plan, today's macros against their targets, what was eaten, and the recipe library.
// Answered as JSON: a line on what the day needs, and 2–4 alternatives, library recipes first, so a pick
// can be added to today with one tap. Library suggestions take their numbers from the recipe, not the reply.

enum NutritionAdvisor {
    static let systemPrompt = """
    You suggest what to eat next for someone tracking food against a calorie plan and macro targets. You get \
    the time, the kcal left to land exactly on today's plan (negative means already over it), today's macros \
    against targets (a "min" to reach, a "max" to stay under, an "aim" to land near), what was eaten today, \
    an optional note from the user, and their recipe library with numbers per serving.

    Reply with ONE JSON object and nothing else:
    {"summary": "one or two sentences: what today still needs and why",
     "suggestions": [{"recipeId": "an id from the library, or null", "name": "the food", "portion": 1,
                      "kcal": 0, "proteinG": 0, "why": "one short line"}]}

    Rules:
    - 2 to 4 suggestions, best first. Each is an ALTERNATIVE that fits the kcal left on its own.
    - Prefer the library: give its id, a portion from 0.25, 0.33, 0.5, 1, 1.5, 2, 3, and its numbers × the \
    portion. At most one suggestion from outside the library, with your own estimate and recipeId null.
    - Close the biggest gap first. Protein under its min → lean protein (grilled chicken, eggs, whey, Greek \
    yogurt). Protein met but kcal left → complex carbs, fruit, or a small amount of dark chocolate, or \
    unsaturated fat (nuts) if that is short. Fibre short → fibre-rich choices.
    - Never push a "max" (saturated fat, sugar) past its limit. The limits encode health constraints.
    - Mind the clock: late evening, favour light, easy-to-digest food and no caffeine.
    - Under about 50 kcal left, or over the plan: say so in the summary and suggest nothing, or one very \
    low-kcal option in case of real hunger.
    - Indian home cooking is common. Plain numbers, no units in values.
    """

    struct Suggestion: Equatable, Identifiable {
        var id: Int
        /// Set only when it names a recipe in the library.
        var recipeId: String?
        var name: String
        var portion: Double
        var kcal: Double
        var proteinG: Double
        var why: String
    }

    struct Advice: Equatable {
        var summary: String
        var suggestions: [Suggestion]
    }

    struct Context {
        var now: Date
        /// kcal to eat to land on plan: minus the card's headline total.
        var kcalLeft: Int
        var inKcal: Int
        var outKcal: Int
        var totals: NutritionMacros
        var targets: [NutritionMacro: Int]
        var eaten: [NutritionItem]
        var recipes: [String: NutritionRecipe]
        var note: String
    }

    enum Failure: LocalizedError {
        case unreadable
        var errorDescription: String? { "The reply wasn't a suggestion list. Try again." }
    }

    @MainActor
    static func ask(coach: AICoachEngine, _ context: Context) async throws -> Advice {
        let model: String? = coach.provider == .anthropic ? NutritionEstimator.sonnetModel : nil
        let reply = try await coach.oneShotVision(systemPrompt: systemPrompt, text: prompt(context), images: [],
                                                  model: model)
        guard let advice = parse(reply, recipes: context.recipes) else { throw Failure.unreadable }
        return advice
    }

    /// The library sent along: regular, unarchived recipes, most recently used first, at most `limit`.
    static func library(_ recipes: [String: NutritionRecipe], limit: Int = 150) -> [NutritionRecipe] {
        recipes.values.filter { !$0.oneOff && !$0.archived }
            .sorted { a, b in
                let ua = a.lastUsedTs ?? 0, ub = b.lastUsedTs ?? 0
                return ua == ub ? a.name < b.name : ua > ub
            }
            .prefix(limit).map { $0 }
    }

    static func prompt(_ c: Context) -> String {
        func g(_ v: Double) -> String { v < 10 ? String(format: "%.1f", v) : "\(Int(v.rounded()))" }
        let time = c.now.formatted(.dateTime.weekday(.wide).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        var lines = [
            "Time now: \(time)",
            "kcal left to land on plan: \(c.kcalLeft) (planned intake so far \(c.inKcal), burn so far \(c.outKcal))",
            "",
            "Macros today vs targets:",
        ]
        for m in NutritionMacro.allCases {
            let v = m.grams(c.totals), t = Double(c.targets[m] ?? m.defaultGrams)
            let gap: String
            switch m.kind {
            case .floor: gap = v >= t ? "met" : "\(g(t - v)) g to go"
            case .cap: gap = v > t ? "\(g(v - t)) g OVER" : "\(g(t - v)) g left"
            case .aim: gap = v < t ? "\(g(t - v)) g under" : "\(g(v - t)) g over"
            }
            lines.append("- \(m.rawValue): \(g(v)) g, \(m.kindWord) \(Int(t)) (\(gap))")
        }
        lines += ["", "Eaten today:"]
        if c.eaten.isEmpty { lines.append("- nothing logged") }
        for item in c.eaten {
            let r = c.recipes[item.recipeId]
            let kcal = (r?.macros.kcal ?? 0) * item.portion
            lines.append("- \(NutritionDayEditor.portionLabel(item.portion)) \(r?.name ?? item.recipeId) (\(Int(kcal.rounded())) kcal)")
        }
        let note = c.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { lines += ["", "Note from the user: \(note)"] }
        lines += ["", "Library (id | name | serving | kcal protein carbs fibre sugar fat satFat per serving):"]
        for r in library(c.recipes) {
            let m = r.macros
            lines.append("\(r.id) | \(r.name) | \(r.serving) | \(g(m.kcal)) \(g(m.proteinG)) \(g(m.carbsG)) "
                         + "\(g(m.fiberG)) \(g(m.sugarG)) \(g(m.fatG)) \(g(m.satFatG))")
        }
        return lines.joined(separator: "\n")
    }

    /// The JSON object in a reply (tolerates code fences or a sentence around it). A recipeId not in the
    /// library is dropped to null; a library suggestion's portion snaps to the editor's portions and its
    /// numbers come from the recipe.
    static func parse(_ reply: String, recipes: [String: NutritionRecipe]) -> Advice? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func num(_ d: [String: Any], _ k: String) -> Double? {
            if let n = d[k] as? NSNumber { return n.doubleValue }
            if let s = d[k] as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
            return nil
        }
        let raw = obj["suggestions"] as? [[String: Any]] ?? []
        let suggestions = raw.enumerated().compactMap { i, s -> Suggestion? in
            let recipe = (s["recipeId"] as? String).flatMap { recipes[$0] }
            let why = (s["why"] as? String) ?? ""
            if let recipe {
                let p = snap(num(s, "portion") ?? 1)
                return Suggestion(id: i, recipeId: recipe.id, name: recipe.name, portion: p,
                                  kcal: recipe.macros.kcal * p, proteinG: recipe.macros.proteinG * p, why: why)
            }
            guard let name = s["name"] as? String, !name.isEmpty else { return nil }
            return Suggestion(id: i, recipeId: nil, name: name, portion: num(s, "portion") ?? 1,
                              kcal: num(s, "kcal") ?? 0, proteinG: num(s, "proteinG") ?? 0, why: why)
        }
        let summary = (obj["summary"] as? String) ?? ""
        guard !summary.isEmpty || !suggestions.isEmpty else { return nil }
        return Advice(summary: summary, suggestions: suggestions)
    }

    /// The nearest of the editor's portions.
    static func snap(_ p: Double) -> Double {
        NutritionDayEditor.portions.min { abs($0 - p) < abs($1 - p) } ?? 1
    }
}
