import Foundation
import WhoopStore

// nikhil/custom — the app's door to the nutrition tables (`WhoopStore` NutritionStore): the schema is made
// on first use, days resolve against the dated standard versions, and the HealthVault's one-time import
// file (`Tools/nutrition/vault_to_import.py`, format in plans/nutrition-tracking.md) is applied here.

enum NutritionPrefs {
    /// Settings → Nutrition. Off by default so an install that never set it up shows nothing.
    static let enabledKey = "noop.nutritionEnabled"
}

/// Bumped after any nutrition write, so cards re-read (Repository is upstream; this keeps the signal here).
@MainActor
final class NutritionChanges: ObservableObject {
    static let shared = NutritionChanges()
    @Published private(set) var seq = 0
    func bump() { seq &+= 1 }
}

extension Repository {
    /// The store with the nutrition tables guaranteed to exist.
    func nutritionStore() async -> WhoopStore? {
        guard let store = await storeHandle() else { return nil }
        do { try await store.ensureNutritionSchema() } catch { return nil }
        return store
    }

    /// Days in [from, to] (yyyy-MM-dd, inclusive), each resolved: stored rows, else the standard in force
    /// on that day, else nothing (before tracking began).
    func nutritionDays(from: String, to: String) async -> [NutritionDay] {
        guard let store = await nutritionStore() else { return [] }
        let versions = (try? await store.nutritionStandardVersions()) ?? []
        let stored = (try? await store.nutritionStoredDays(from: from, to: to)) ?? [:]
        let locks = (try? await store.nutritionLocks(from: from, to: to)) ?? [:]
        return Self.dayKeys(from: from, to: to).map { key in
            var day = NutritionResolve.day(key, stored: stored[key], versions: versions)
            day.lockedAt = locks[key]
            return day
        }
    }

    func nutritionDay(_ key: String) async -> NutritionDay {
        await nutritionDays(from: key, to: key).first ?? NutritionDay(day: key, state: .none, items: [])
    }

    /// yyyy-MM-dd keys from `from` to `to`, in order; empty when reversed or unparsable.
    static func dayKeys(from: String, to: String) -> [String] {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        guard var d = f.date(from: from), let end = f.date(from: to), d <= end else { return [] }
        var out: [String] = []
        let cal = Calendar(identifier: .gregorian)
        while d <= end, out.count < 3700 {
            out.append(f.string(from: d))
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return out
    }
}

// MARK: - Vault import file

/// The import file, version 1. Decoding is strict about shape and lenient about missing numbers (0).
struct NutritionImportFile: Decodable {
    struct Macros: Decodable {
        var kcal, proteinG, carbsG, fiberG, sugarG, fatG, satFatG: Double?
        var sodiumMg: Double?
        var value: NutritionMacros {
            NutritionMacros(kcal: kcal ?? 0, proteinG: proteinG ?? 0, carbsG: carbsG ?? 0, fiberG: fiberG ?? 0,
                            sugarG: sugarG ?? 0, fatG: fatG ?? 0, satFatG: satFatG ?? 0, sodiumMg: sodiumMg)
        }
    }
    struct Part: Decodable {
        var name: String
        var macros: Macros
        init(from decoder: Decoder) throws {
            name = try decoder.container(keyedBy: Key.self).decode(String.self, forKey: .name)
            macros = try Macros(from: decoder)
        }
        enum Key: String, CodingKey { case name }
    }
    struct Recipe: Decodable {
        var id, name: String
        var serving: String?
        var category: String?
        var oneOff: Bool?
        var notes: String?
        var parts: [Part]?
        var macros: Macros
        enum Key: String, CodingKey { case id, name, serving, category, oneOff, notes, parts }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            serving = try c.decodeIfPresent(String.self, forKey: .serving)
            category = try c.decodeIfPresent(String.self, forKey: .category)
            oneOff = try c.decodeIfPresent(Bool.self, forKey: .oneOff)
            notes = try c.decodeIfPresent(String.self, forKey: .notes)
            parts = try c.decodeIfPresent([Part].self, forKey: .parts)
            macros = try Macros(from: decoder)
        }
    }
    struct Item: Decodable {
        var label: String
        var minuteOfDay: Int?
        var recipeId: String
        var portion: Double?
        var swaps: [String]?
        var value: NutritionItem {
            NutritionItem(label: label, minuteOfDay: minuteOfDay, recipeId: recipeId, portion: portion ?? 1,
                          swaps: swaps ?? [])
        }
    }
    struct Standard: Decodable { var effectiveDay: String; var slots: [Item] }
    struct Day: Decodable { var day: String; var state: String; var items: [Item]? }

    var version: Int
    var recipes: [Recipe]
    var standard: Standard?
    var days: [Day]?

    struct Unsupported: LocalizedError {
        let version: Int
        var errorDescription: String? { "This import file is version \(version); this build reads version 1." }
    }

    static func decode(_ data: Data) throws -> NutritionImportFile {
        let file = try JSONDecoder().decode(NutritionImportFile.self, from: data)
        guard file.version == 1 else { throw Unsupported(version: file.version) }
        return file
    }
}

extension Repository {
    /// Apply a vault import file. Returns a one-line summary for the screen.
    func importNutrition(_ data: Data) async throws -> String {
        let file = try NutritionImportFile.decode(data)
        guard let store = await nutritionStore() else { throw CocoaError(.fileReadUnknown) }
        let now = Int(Date().timeIntervalSince1970)
        let recipes = file.recipes.map { r in
            NutritionRecipe(id: r.id, name: r.name, serving: r.serving ?? "1 serving", category: r.category,
                            macros: r.macros.value,
                            parts: (r.parts ?? []).map { NutritionRecipePart(name: $0.name, macros: $0.macros.value) },
                            notes: r.notes ?? "", oneOff: r.oneOff ?? false, createdAt: now, updatedAt: now)
        }
        let days: [(day: String, state: NutritionDayState, items: [NutritionItem])] = (file.days ?? []).compactMap { d in
            guard let state = NutritionDayState(rawValue: d.state), state == .edited || state == .untracked else { return nil }
            return (d.day, state, (d.items ?? []).map(\.value))
        }
        let result = try await store.importNutrition(
            recipes: recipes,
            standard: file.standard.map { (effectiveDay: $0.effectiveDay, slots: $0.slots.map(\.value)) },
            days: days, at: now)
        await NutritionChanges.shared.bump()
        let regular = recipes.filter { !$0.oneOff }.count
        var summary = String(localized: "\(regular) recipes, \(recipes.count - regular) one-offs, \(result.days) days imported")
        if result.skippedDays > 0 {
            summary += String(localized: " · \(result.skippedDays) days kept as edited in the app")
        }
        return summary
    }
}

// MARK: - Editing a day

extension Repository {
    /// Change a day's rows. The first edit copies the resolved rows (keeping the standard slot ids, so a
    /// swapped row still counts as standard) and gives the day its own list; later edits replace it.
    /// Recipes added or swapped in are marked used, and a one-off used again becomes a regular recipe;
    /// `justCreated` names a one-off made for this edit, which stays a one-off.
    func editNutritionDay(_ key: String, justCreated: Set<String> = [], _ change: (inout [NutritionItem]) -> Void) async {
        guard let store = await nutritionStore() else { return }
        let current = await nutritionDay(key)
        var items = current.state == .untracked || current.state == .none ? [] : current.items
        let before = Set(items.map { "\($0.id)|\($0.recipeId)" })
        change(&items)
        let now = Int(Date().timeIntervalSince1970)
        try? await store.saveNutritionDay(key, items: items, at: now)
        let newlyUsed = items.filter { !before.contains("\($0.id)|\($0.recipeId)") }.map(\.recipeId)
        // Picking a recipe for a new row is using it again, except for a one-off made for this very row.
        let reused = newlyUsed.filter { !justCreated.contains($0) }
        try? await store.touchNutritionRecipes(ids: reused, at: now, promoteOneOffs: true)
        try? await store.touchNutritionRecipes(ids: newlyUsed.filter { justCreated.contains($0) }, at: now,
                                               promoteOneOffs: false)
        await NutritionChanges.shared.bump()
    }

    func setNutritionDayUntracked(_ key: String, _ untracked: Bool) async {
        guard let store = await nutritionStore() else { return }
        try? await store.setNutritionDayUntracked(key, untracked, at: Int(Date().timeIntervalSince1970))
        await NutritionChanges.shared.bump()
    }

    /// Lock a day as final (journal finished, or the following day ended with it unfilled).
    func lockNutritionDay(_ key: String) async {
        guard let store = await nutritionStore() else { return }
        try? await store.lockNutritionDay(key, at: Int(Date().timeIntervalSince1970))
        await NutritionChanges.shared.bump()
    }

    /// Save a recipe (new, edited, or estimated) and signal the change.
    func saveNutritionRecipe(_ recipe: NutritionRecipe) async {
        guard let store = await nutritionStore() else { return }
        try? await store.upsertNutritionRecipes([recipe])
        await NutritionChanges.shared.bump()
    }

    func nutritionRecipeList() async -> [String: NutritionRecipe] {
        guard let store = await nutritionStore() else { return [:] }
        return (try? await store.nutritionRecipes()) ?? [:]
    }

    /// Save the standard day as a new version from today. Today follows it unless already edited.
    func saveNutritionStandard(_ slots: [NutritionItem]) async {
        guard let store = await nutritionStore() else { return }
        try? await store.saveNutritionStandard(slots: slots, effectiveDay: Repository.localDayKey(Date()),
                                               createdAt: Int(Date().timeIntervalSince1970))
        await NutritionChanges.shared.bump()
    }

    /// The standard slots in force on `key` (empty before the first version).
    func nutritionStandardSlots(on key: String) async -> [NutritionItem] {
        guard let store = await nutritionStore() else { return [] }
        let versions = (try? await store.nutritionStandardVersions()) ?? []
        return NutritionResolve.standardSlots(on: key, versions: versions) ?? []
    }
}
