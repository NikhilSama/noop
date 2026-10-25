import Foundation

// nikhil/custom — fat mass and lean mass derived from Apple Health body-fat % and weight, for the Key
// Metrics tiles. Lean mass here is weight − fat mass (not Health's own lean_mass series, which most
// scales never write), so the three tiles always add up.

struct BodyCompPoint: Equatable {
    let day: String
    let weightKg: Double
    let bodyFatPct: Double
    var fatKg: Double { weightKg * bodyFatPct / 100 }
    var leanKg: Double { weightKg - fatKg }
}

enum BodyComposition {
    /// One point per body-fat reading, paired with the latest weight on or before that day. A body-fat
    /// day with no weight yet is skipped. Inputs are day-keyed ("yyyy-MM-dd"), any order.
    static func series(weight: [(day: String, value: Double)],
                       bodyFat: [(day: String, value: Double)]) -> [BodyCompPoint] {
        let weights = weight.sorted { $0.day < $1.day }
        var out: [BodyCompPoint] = []
        var wi = 0
        var lastWeight: Double?
        for bf in bodyFat.sorted(by: { $0.day < $1.day }) {
            while wi < weights.count, weights[wi].day <= bf.day {
                lastWeight = weights[wi].value
                wi += 1
            }
            if let w = lastWeight, bf.value.isFinite, bf.value > 0, bf.value < 100 {
                out.append(BodyCompPoint(day: bf.day, weightKg: w, bodyFatPct: bf.value))
            }
        }
        return out
    }
}
