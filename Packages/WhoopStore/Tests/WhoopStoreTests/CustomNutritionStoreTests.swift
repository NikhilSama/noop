import XCTest
@testable import WhoopStore

/// nikhil/custom — the nutrition tables: recipes, dated standard versions, day resolution and import.
final class CustomNutritionStoreTests: XCTestCase {
    private func store() async throws -> WhoopStore {
        let s = try await WhoopStore.inMemory()
        try await s.ensureNutritionSchema()
        try await s.ensureNutritionSchema()   // idempotent
        return s
    }

    private func recipe(_ id: String, kcal: Double, protein: Double = 0, oneOff: Bool = false) -> NutritionRecipe {
        NutritionRecipe(id: id, name: id, serving: "1", macros: NutritionMacros(kcal: kcal, proteinG: protein),
                        parts: [NutritionRecipePart(name: "a", macros: NutritionMacros(kcal: kcal))],
                        oneOff: oneOff, createdAt: 1, updatedAt: 1)
    }

    private func slot(_ recipe: String, _ portion: Double = 1) -> NutritionItem {
        NutritionItem(label: recipe, minuteOfDay: 810, recipeId: recipe, portion: portion)
    }

    func testSchemaStaysOutOfTheUpstreamMigrator() async throws {
        let plain = try await WhoopStore.inMemory()
        let tables = try await plain.tableNames()
        XCTAssertFalse(tables.contains("nutritionRecipe"), "upstream schema oracle must not see fork tables")
        let s = try await store()
        let withNutrition = try await s.tableNames()
        for t in ["nutritionRecipe", "nutritionRecipePart", "nutritionStandardVersion", "nutritionStandardSlot",
                  "nutritionDay", "nutritionDayItem", "nutritionMeta"] {
            XCTAssertTrue(withNutrition.contains(t), "missing \(t)")
        }
    }

    func testRecipesRoundTripWithParts() async throws {
        let s = try await store()
        var r = recipe("standard-lunch", kcal: 552, protein: 34)
        r.macros.sodiumMg = 400
        r.parts = [NutritionRecipePart(name: "2 whole eggs", macros: NutritionMacros(kcal: 144, proteinG: 12.6)),
                   NutritionRecipePart(name: "Daal", macros: NutritionMacros(kcal: 150, proteinG: 9))]
        try await s.upsertNutritionRecipes([r])
        try await s.upsertNutritionRecipes([r])   // re-upsert: no duplicate parts
        let all = try await s.nutritionRecipes()
        XCTAssertEqual(all["standard-lunch"], r)
    }

    func testAnUntouchedDayIsTheStandardInForceThen() async throws {
        let s = try await store()
        try await s.upsertNutritionRecipes([recipe("keema", kcal: 345), recipe("salmon", kcal: 368)])
        try await s.saveNutritionStandard(slots: [slot("keema")], effectiveDay: "2026-11-01", createdAt: 10)
        try await s.saveNutritionStandard(slots: [slot("salmon")], effectiveDay: "2026-11-05", createdAt: 20)
        let versions = try await s.nutritionStandardVersions()
        XCTAssertEqual(NutritionResolve.day("2026-10-31", stored: nil, versions: versions).state, .none)
        XCTAssertEqual(NutritionResolve.day("2026-11-03", stored: nil, versions: versions).items.map(\.recipeId), ["keema"])
        XCTAssertEqual(NutritionResolve.day("2026-11-09", stored: nil, versions: versions).items.map(\.recipeId), ["salmon"])
    }

    func testEditedAndUntrackedDaysAndLocks() async throws {
        let s = try await store()
        try await s.upsertNutritionRecipes([recipe("keema", kcal: 345), recipe("nuts", kcal: 145)])
        try await s.saveNutritionStandard(slots: [slot("keema")], effectiveDay: "2026-11-01", createdAt: 10)
        try await s.saveNutritionDay("2026-11-02", items: [slot("keema", 0.5), slot("nuts")], at: 100)
        try await s.setNutritionDayUntracked("2026-11-03", true, at: 100)
        try await s.lockNutritionDay("2026-11-04", at: 200)   // locked, never edited

        let versions = try await s.nutritionStandardVersions()
        let stored = try await s.nutritionStoredDays(from: "2026-11-01", to: "2026-11-09")
        let recipes = try await s.nutritionRecipes()
        let edited = NutritionResolve.day("2026-11-02", stored: stored["2026-11-02"], versions: versions)
        XCTAssertEqual(edited.state, .edited)
        XCTAssertEqual(edited.totals(recipes: recipes).kcal, 345 * 0.5 + 145, accuracy: 0.001)
        XCTAssertEqual(NutritionResolve.day("2026-11-03", stored: stored["2026-11-03"], versions: versions).state, .untracked)
        let locked = NutritionResolve.day("2026-11-04", stored: stored["2026-11-04"], versions: versions)
        XCTAssertEqual(locked.state, .standard, "a lock alone does not detach a day from the standard")
        let locks = try await s.nutritionLocks(from: "2026-11-01", to: "2026-11-09")
        XCTAssertEqual(locks["2026-11-04"], 200)

        try await s.setNutritionDayUntracked("2026-11-03", false, at: 300)
        let after = try await s.nutritionStoredDays(from: "2026-11-03", to: "2026-11-03")
        XCTAssertNil(after["2026-11-03"], "un-marking puts the day back on the standard")
    }

    func testUsingAOneOffAgainPromotesIt() async throws {
        let s = try await store()
        try await s.upsertNutritionRecipes([recipe("samosa", kcal: 260, oneOff: true)])
        try await s.touchNutritionRecipes(ids: ["samosa"], at: 50, promoteOneOffs: true)
        let r = try await s.nutritionRecipes()["samosa"]
        XCTAssertEqual(r?.oneOff, false)
        XCTAssertEqual(r?.lastUsedTs, 50)
    }

    func testReImportUpdatesAndKeepsAppEdits() async throws {
        let s = try await store()
        let standard = (effectiveDay: "2026-11-09", slots: [slot("keema")])
        let days: [(day: String, state: NutritionDayState, items: [NutritionItem])] =
            [("2026-07-14", .edited, [slot("keema", 2)]), ("2026-07-15", .edited, [slot("keema")])]
        var first = try await s.importNutrition(recipes: [recipe("keema", kcal: 345)], standard: standard, days: days, at: 1000)
        XCTAssertEqual(first.days, 2)

        // The user edits one imported day in the app after the import…
        try await s.saveNutritionDay("2026-07-15", items: [slot("keema", 0.5)], at: 2000)
        // …and the vault is imported again with a corrected recipe.
        first = try await s.importNutrition(recipes: [recipe("keema", kcal: 350)], standard: standard, days: days, at: 3000)
        XCTAssertEqual(first.days, 1)
        XCTAssertEqual(first.skippedDays, 1)

        let recipes = try await s.nutritionRecipes()
        XCTAssertEqual(recipes.count, 1)
        XCTAssertEqual(recipes["keema"]?.macros.kcal, 350)
        let versions = try await s.nutritionStandardVersions()
        XCTAssertEqual(versions.count, 1, "an unchanged standard is not saved twice")
        let stored = try await s.nutritionStoredDays(from: "2026-07-01", to: "2026-07-31")
        XCTAssertEqual(stored["2026-07-15"]?.items.first?.portion, 0.5, "the app edit survives the re-import")
    }

    func testSodiumStaysUnknownUnlessSomePartKnowsIt() {
        let a = NutritionMacros(kcal: 1), b = NutritionMacros(kcal: 2)
        XCTAssertNil((a + b).sodiumMg)
        XCTAssertEqual((a + NutritionMacros(sodiumMg: 30)).sodiumMg, 30)
        XCTAssertEqual(NutritionMacros(kcal: 100, sodiumMg: 10).scaled(1.5).kcal, 150)
    }
}
