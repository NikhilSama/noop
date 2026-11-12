import XCTest
import WhoopStore
import StrandDesign
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

// nikhil/custom — the card's headline / equation and the colour bands it shares with the watch.
final class CustomNutritionEquationTests: XCTestCase {
    func testEquationIncludesPlannedDeficitAndAddsUpAsPrinted() {
        let b = NutritionBalance(standardKcal: 1428.4, extraKcal: 0, fullStandardKcal: 1428.4, rmrKcal: 1217,
                                 tefKcal: 142.84, activeKcal: 353.6, targetBalance: -300)
        let e = b.equation
        XCTAssertEqual(e.total, 1428 + 300 - (1217 + 143 + 354))
        XCTAssertEqual(NutritionTodayCard.equationText(e), "+14 = 1428 (1428 + 0) + 300 − 1714 (1217 + 143 + 354)")
        // A surplus target subtracts.
        var s = b; s.targetBalance = 200
        XCTAssertTrue(NutritionTodayCard.equationText(s.equation).contains(") − 200 − "))
    }

    func testBands() {
        XCTAssertEqual(NutritionBand.of(offPlan: 90, target: -300), .onPlan)
        XCTAssertEqual(NutritionBand.of(offPlan: -100, target: -300), .onPlan)
        XCTAssertEqual(NutritionBand.of(offPlan: 250, target: -300), .near)   // still a deficit, not the plan
        XCTAssertEqual(NutritionBand.of(offPlan: 301, target: -300), .off)    // a real surplus
        XCTAssertEqual(NutritionBand.of(offPlan: -450, target: -300), .off)   // eating far too little
        XCTAssertEqual(NutritionBand.of(offPlan: 150, target: 0), .off)       // no yellow without a deficit
        XCTAssertEqual(NutritionBand.of(offPlan: 700, target: -800), .near)
    }

    func testWatchTransferRationing() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func snap(_ n: Int, day: String = "2026-11-10") -> WatchNutritionSnapshot {
            WatchNutritionSnapshot(day: day, offPlanKcal: n, targetKcal: -300, inKcal: 0, outKcal: 0, asOf: t0)
        }
        let due = WatchNutritionSnapshot.transferDue
        XCTAssertTrue(due(nil, snap(20), t0))
        // Same band, small move: not worth one, however late.
        XCTAssertFalse(due((snap(20), t0), snap(55), t0.addingTimeInterval(3600)))
        // Band change (green to yellow): at once.
        XCTAssertTrue(due((snap(20), t0), snap(150), t0.addingTimeInterval(60)))
        // Same band, big move: only after 30 minutes.
        XCTAssertFalse(due((snap(150), t0), snap(200), t0.addingTimeInterval(600)))
        XCTAssertTrue(due((snap(150), t0), snap(200), t0.addingTimeInterval(1900)))
        XCTAssertTrue(due((snap(20), t0), snap(20, day: "2026-11-11"), t0))
    }
}

// nikhil/custom — the Portion menu's labels.
final class CustomNutritionPortionTests: XCTestCase {
    func testLabels() {
        XCTAssertEqual(NutritionDayEditor.portions.map(NutritionDayEditor.portionLabel), ["¼", "⅓", "½", "1×", "1½", "2×", "3×"])
        XCTAssertEqual(NutritionDayEditor.portionPrefix(1), "")
        XCTAssertEqual(NutritionDayEditor.portionPrefix(1.0 / 3), "⅓ ")
    }
}

/// nikhil/custom — the macro rings' bands and the "What should I eat?" request and reply.
final class CustomNutritionMacroTests: XCTestCase {
    private let recipes: [String: NutritionRecipe] = [
        "chicken": NutritionRecipe(id: "chicken", name: "Grilled chicken", serving: "150 g",
                                   macros: NutritionMacros(kcal: 240, proteinG: 45, fatG: 5, satFatG: 1.5),
                                   createdAt: 0, updatedAt: 0, lastUsedTs: 10),
        "choc": NutritionRecipe(id: "choc", name: "Dark chocolate 85%", serving: "20 g",
                                macros: NutritionMacros(kcal: 120, proteinG: 2, carbsG: 4, fiberG: 2, sugarG: 3, fatG: 10, satFatG: 6),
                                createdAt: 0, updatedAt: 0, lastUsedTs: 20),
        "old": NutritionRecipe(id: "old", name: "Archived thing", serving: "1", macros: NutritionMacros(kcal: 99),
                               archived: true, createdAt: 0, updatedAt: 0),
    ]

    func testTotalsScaleByPortionAndUnsaturatedIsFatLessSaturated() {
        let items = [NutritionItem(label: "Dinner", minuteOfDay: 1200, recipeId: "chicken", portion: 2),
                     NutritionItem(label: "Treat", minuteOfDay: 1300, recipeId: "choc", portion: 0.5),
                     NutritionItem(label: "Gone", minuteOfDay: nil, recipeId: "missing")]
        let t = NutritionMacro.totals(items, recipes: recipes)
        XCTAssertEqual(t.kcal, 540, accuracy: 0.001)
        XCTAssertEqual(NutritionMacro.protein.grams(t), 91, accuracy: 0.001)
        XCTAssertEqual(NutritionMacro.satFat.grams(t), 6, accuracy: 0.001)
        XCTAssertEqual(NutritionMacro.unsatFat.grams(t), 15 - 6, accuracy: 0.001)
    }

    func testFloorsCapsAndAimsBand() {
        XCTAssertEqual(NutritionMacro.protein.status(139, target: 140), .short)
        XCTAssertEqual(NutritionMacro.protein.status(140, target: 140), .good)
        XCTAssertEqual(NutritionMacro.satFat.status(11, target: 13), .good)
        XCTAssertEqual(NutritionMacro.satFat.status(11.1, target: 13), .near)
        XCTAssertEqual(NutritionMacro.satFat.status(13.1, target: 13), .over)
        XCTAssertEqual(NutritionMacro.carbs.status(100, target: 140), .short)
        XCTAssertEqual(NutritionMacro.carbs.status(150, target: 140), .good)
        XCTAssertEqual(NutritionMacro.carbs.status(175, target: 140), .near)
        XCTAssertEqual(NutritionMacro.carbs.status(190, target: 140), .over)
    }

    func testDefaultsAreTheVaultsTargets() {
        XCTAssertEqual(NutritionMacro.protein.defaultGrams, 140)
        XCTAssertEqual(NutritionMacro.satFat.defaultGrams, 13)
        XCTAssertEqual(NutritionMacro.allCases.map(\.kind), [.floor, .floor, .aim, .cap, .floor, .cap])
    }

    func testPromptCarriesGapsEatenFoodNoteAndOnlyTheActiveLibrary() {
        let items = [NutritionItem(label: "Lunch", minuteOfDay: 780, recipeId: "chicken")]
        var targets: [NutritionMacro: Int] = [:]
        for m in NutritionMacro.allCases { targets[m] = m.defaultGrams }
        let c = NutritionAdvisor.Context(now: Date(timeIntervalSince1970: 1_800_000_000), kcalLeft: 300, inKcal: 1400,
                                         outKcal: 2000, totals: NutritionMacro.totals(items, recipes: recipes),
                                         targets: targets, eaten: items, recipes: recipes, note: "craving sweet")
        let p = NutritionAdvisor.prompt(c)
        XCTAssertTrue(p.contains("kcal left to land on plan: 300"))
        XCTAssertTrue(p.contains("- protein: 45 g, min 140 (95 g to go)"))
        XCTAssertTrue(p.contains("- satFat: 1.5 g, max 13 (12 g left)"))
        XCTAssertTrue(p.contains("- 1× Grilled chicken (240 kcal)"))
        XCTAssertTrue(p.contains("Note from the user: craving sweet"))
        XCTAssertTrue(p.contains("choc | Dark chocolate 85% | 20 g | 120 2.0 4.0 2.0 3.0 10 6.0"))
        XCTAssertFalse(p.contains("Archived thing"))
        // Most recently used first.
        XCTAssertLessThan(p.range(of: "choc |")!.lowerBound, p.range(of: "chicken |")!.lowerBound)
    }

    func testReplyTakesLibraryNumbersSnapsPortionsAndDropsUnknownIds() {
        let reply = """
        Here you go:
        ```json
        {"summary": "Protein is done; 300 kcal left.",
         "suggestions": [
          {"recipeId": "choc", "name": "chocolate", "portion": 0.4, "kcal": 999, "proteinG": 99, "why": "sweet, fits"},
          {"recipeId": "nope", "name": "Oats with milk", "portion": 1, "kcal": 250, "proteinG": 10, "why": "complex carbs"},
          {"recipeId": null, "name": "", "kcal": 1}
         ]}
        ```
        """
        let a = NutritionAdvisor.parse(reply, recipes: recipes)
        XCTAssertEqual(a?.summary, "Protein is done; 300 kcal left.")
        XCTAssertEqual(a?.suggestions.count, 2)
        let choc = a?.suggestions[0]
        XCTAssertEqual(choc?.recipeId, "choc")
        XCTAssertEqual(choc?.name, "Dark chocolate 85%")
        XCTAssertEqual(choc?.portion ?? 0, 1.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(choc?.kcal ?? 0, 40, accuracy: 0.001)
        let oats = a?.suggestions[1]
        XCTAssertNil(oats?.recipeId)
        XCTAssertEqual(oats?.kcal, 250)
        XCTAssertNil(NutritionAdvisor.parse("no json here", recipes: recipes))
    }
}
