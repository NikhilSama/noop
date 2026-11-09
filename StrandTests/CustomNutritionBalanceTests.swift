import XCTest
import WhoopStore
@testable import Strand

/// nikhil/custom — the Today nutrition card's in/out arithmetic.
final class CustomNutritionBalanceTests: XCTestCase {
    private let recipes: [String: NutritionRecipe] = [
        "lunch": NutritionRecipe(id: "lunch", name: "Standard Lunch", serving: "1", macros: NutritionMacros(kcal: 552), createdAt: 0, updatedAt: 0),
        "kefir": NutritionRecipe(id: "kefir", name: "Kefir smoothie", serving: "1", macros: NutritionMacros(kcal: 190), createdAt: 0, updatedAt: 0),
        "nuts": NutritionRecipe(id: "nuts", name: "Mixed nuts", serving: "1", macros: NutritionMacros(kcal: 145), createdAt: 0, updatedAt: 0),
    ]
    private let slots = [NutritionItem(id: "s1", label: "Lunch", minuteOfDay: 810, recipeId: "lunch"),
                         NutritionItem(id: "s2", label: "Kefir", minuteOfDay: 1140, recipeId: "kefir")]

    func testAnUntouchedDayIsAllStandardAndOutIsRestingPlusDigestionPlusActive() {
        let day = NutritionDay(day: "2026-11-09", state: .standard, items: slots)
        let b = NutritionBalance.make(day: day, standardSlots: slots, recipes: recipes, appleActiveKcal: 300,
                                      strapDayKcal: nil, dayFraction: 0.5, rmr: 1217, tefPercent: 10, target: -300)
        XCTAssertEqual(b.standardKcal, 742)
        XCTAssertEqual(b.extraKcal, 0)
        XCTAssertEqual(b.tefKcal, 74.2, accuracy: 0.001)
        XCTAssertEqual(b.outKcal, 1217 + 74.2 + 300, accuracy: 0.001)
        XCTAssertEqual(b.balance, 742 - 1591.2, accuracy: 0.001)
        XCTAssertTrue(b.hit)
    }

    func testEditsMoveTheStandardAndExtraSegments() {
        // Kefir halved (keeps its slot id), nuts added.
        let day = NutritionDay(day: "d", state: .edited, items: [
            slots[0], NutritionItem(id: "s2", label: "Kefir", minuteOfDay: 1140, recipeId: "kefir", portion: 0.5),
            NutritionItem(id: "x", label: "Snack", minuteOfDay: 1000, recipeId: "nuts")])
        let b = NutritionBalance.make(day: day, standardSlots: slots, recipes: recipes, appleActiveKcal: nil,
                                      strapDayKcal: nil, dayFraction: 1, rmr: 1217, tefPercent: 10, target: -300)
        XCTAssertEqual(b.standardKcal, 552 + 95)
        XCTAssertEqual(b.extraKcal, 145)
        XCTAssertEqual(b.fullStandardKcal, 742)
    }

    func testActiveAveragesAppleWithTheStrapLessRestingSoFar() {
        // Strap whole-day 1,000 at mid-day: 1,000 − 1,217 × 0.5 = 391.5; Apple 300 → average 345.75.
        XCTAssertEqual(NutritionBalance.active(apple: 300, strapDay: 1000, rmr: 1217, dayFraction: 0.5), 345.75, accuracy: 0.001)
        XCTAssertEqual(NutritionBalance.active(apple: nil, strapDay: 500, rmr: 1217, dayFraction: 1), 0)
        XCTAssertEqual(NutritionBalance.active(apple: 220, strapDay: nil, rmr: 1217, dayFraction: 1), 220)
        XCTAssertEqual(NutritionBalance.active(apple: nil, strapDay: nil, rmr: 1217, dayFraction: 1), 0)
    }

    func testToGoAndTheTrimSuggestion() {
        let day = NutritionDay(day: "d", state: .standard, items: slots)
        let b = NutritionBalance.make(day: day, standardSlots: slots, recipes: recipes, appleActiveKcal: 0,
                                      strapDayKcal: nil, dayFraction: 0.2, rmr: 600, tefPercent: 10, target: -300)
        // in 742, out 600 + 74.2 → balance +67.8, target −300 → 367.8 to go.
        XCTAssertEqual(b.toGo, 367.8, accuracy: 0.001)
        XCTAssertFalse(b.hit)
        // Need 80: halving kefir (95) is the smallest half that covers it.
        XCTAssertEqual(NutritionBalance.trimSuggestion(items: slots, recipes: recipes, need: 80)?.name, "Kefir smoothie")
        // Need 500: nothing covers it, so the biggest half (lunch, 276).
        XCTAssertEqual(NutritionBalance.trimSuggestion(items: slots, recipes: recipes, need: 500)?.saves, 276)
    }
}

/// nikhil/custom — reading the estimator's reply and the evening top-up order.
final class CustomNutritionEstimatorTests: XCTestCase {
    func testParsesAFencedReplyAndTotalsTheParts() {
        let reply = """
        Here you go:
        ```json
        {"name": "Dal makhani", "serving": "1 bowl (250 g)", "notes": "assumed 1 tbsp butter",
         "parts": [{"name": "Dal", "kcal": 220, "proteinG": "11", "carbsG": 28, "fiberG": 8, "sugarG": 2, "fatG": 6, "satFatG": 2},
                   {"name": "Butter 1 tbsp", "kcal": 102, "proteinG": 0.1, "fatG": 11.5, "satFatG": 7.3, "sodiumMg": 90}]}
        ```
        """
        let e = NutritionEstimator.parse(reply)
        XCTAssertEqual(e?.name, "Dal makhani")
        XCTAssertEqual(e?.parts.count, 2)
        XCTAssertEqual(e?.totals.kcal, 322)
        XCTAssertEqual(e?.totals.proteinG ?? 0, 11.1, accuracy: 0.0001)
        XCTAssertEqual(e?.totals.sodiumMg, 90)
        XCTAssertNil(NutritionEstimator.parse("no json here"))
        XCTAssertNil(NutritionEstimator.parse(#"{"name": "x", "parts": []}"#))
    }

    func testTopUpsFitTheSpareAndFavourProteinAndFibre() {
        func r(_ id: String, _ kcal: Double, _ p: Double, _ f: Double, oneOff: Bool = false) -> NutritionRecipe {
            NutritionRecipe(id: id, name: id, serving: "1", macros: NutritionMacros(kcal: kcal, proteinG: p, fiberG: f),
                            oneOff: oneOff, createdAt: 0, updatedAt: 0)
        }
        let picks = NutritionView.topUps([r("chocolate", 150, 2, 2), r("brownie", 133, 11.3, 4), r("nuts", 145, 5, 2),
                                          r("burger", 600, 40, 5), r("samosa", 140, 3, 2, oneOff: true)], spare: 200)
        XCTAssertEqual(picks.map(\.id), ["brownie", "nuts", "chocolate"])
    }
}

final class CustomNutritionDayKeyTests: XCTestCase {
    func testDayOffsetsCrossMonthsAndYears() {
        XCTAssertEqual(Repository.dayKeys(offset: -1, from: "2026-03-01"), "2026-02-28")
        XCTAssertEqual(Repository.dayKeys(offset: 1, from: "2026-12-31"), "2027-01-01")
        XCTAssertEqual(Repository.dayKeys(from: "2026-10-30", to: "2026-11-02"),
                       ["2026-10-30", "2026-10-31", "2026-11-01", "2026-11-02"])
        XCTAssertEqual(Repository.dayKeys(from: "2026-11-02", to: "2026-11-01"), [])
    }
}
