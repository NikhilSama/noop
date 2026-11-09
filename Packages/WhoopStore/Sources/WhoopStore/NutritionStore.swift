import Foundation
import GRDB

// MARK: - nikhil/custom — nutrition: recipes, the standard day, and each day's food
//
// The app owns the food log; the HealthVault reads it out of the `.noopbak` backup (which is the whole
// SQLite file), so everything lives in this database rather than in UserDefaults.
//
// These tables are deliberately NOT in `Database.makeMigrator()`: that list is the upstream schema, pinned
// against the Android twin by `SchemaOracleTests`, and a fork-only table there would fail it and conflict
// with every upstream migration that follows. `ensureNutritionSchema()` creates them idempotently instead,
// and the app calls it before its first nutrition read. A later column is added the same way, with a
// column check, never by editing a CREATE.
//
// Days resolve like the vault pipeline did: a day with no stored row IS the standard day as it stood on
// that date (versions are dated); the first edit gives the day its own rows. Numbers are never stored on a
// day: an item points at a recipe and a portion, and the recipe holds the per-serving macros.

// MARK: - Values

/// The seven numbers every recipe carries (per serving), plus sodium where it is known.
public struct NutritionMacros: Equatable, Codable, Sendable {
    public var kcal: Double
    public var proteinG: Double
    public var carbsG: Double
    public var fiberG: Double
    public var sugarG: Double
    public var fatG: Double
    public var satFatG: Double
    /// Nil when unknown, which is different from zero: a sum stays nil only if every part is nil.
    public var sodiumMg: Double?

    public init(kcal: Double = 0, proteinG: Double = 0, carbsG: Double = 0, fiberG: Double = 0,
                sugarG: Double = 0, fatG: Double = 0, satFatG: Double = 0, sodiumMg: Double? = nil) {
        self.kcal = kcal; self.proteinG = proteinG; self.carbsG = carbsG; self.fiberG = fiberG
        self.sugarG = sugarG; self.fatG = fatG; self.satFatG = satFatG; self.sodiumMg = sodiumMg
    }

    public static let zero = NutritionMacros()

    public func scaled(_ k: Double) -> NutritionMacros {
        NutritionMacros(kcal: kcal * k, proteinG: proteinG * k, carbsG: carbsG * k, fiberG: fiberG * k,
                        sugarG: sugarG * k, fatG: fatG * k, satFatG: satFatG * k, sodiumMg: sodiumMg.map { $0 * k })
    }

    public static func + (a: NutritionMacros, b: NutritionMacros) -> NutritionMacros {
        let sodium: Double? = (a.sodiumMg == nil && b.sodiumMg == nil) ? nil : (a.sodiumMg ?? 0) + (b.sodiumMg ?? 0)
        return NutritionMacros(kcal: a.kcal + b.kcal, proteinG: a.proteinG + b.proteinG, carbsG: a.carbsG + b.carbsG,
                               fiberG: a.fiberG + b.fiberG, sugarG: a.sugarG + b.sugarG, fatG: a.fatG + b.fatG,
                               satFatG: a.satFatG + b.satFatG, sodiumMg: sodium)
    }

    public static func sum<S: Sequence>(_ items: S) -> NutritionMacros where S.Element == NutritionMacros {
        items.reduce(.zero, +)
    }

    fileprivate init(row: Row) {
        self.init(kcal: row["kcal"], proteinG: row["proteinG"], carbsG: row["carbsG"], fiberG: row["fiberG"],
                  sugarG: row["sugarG"], fatG: row["fatG"], satFatG: row["satFatG"], sodiumMg: row["sodiumMg"])
    }

    fileprivate var arguments: [DatabaseValueConvertible?] {
        [kcal, proteinG, carbsG, fiberG, sugarG, fatG, satFatG, sodiumMg]
    }
}

/// One line of a recipe's parts table ("2 whole eggs").
public struct NutritionRecipePart: Equatable, Codable, Sendable {
    public var name: String
    public var macros: NutritionMacros

    public init(name: String, macros: NutritionMacros) {
        self.name = name; self.macros = macros
    }
}

/// A recipe: per-serving totals, the parts they came from, and where the estimate came from.
public struct NutritionRecipe: Equatable, Codable, Sendable, Identifiable {
    /// The vault note's stem for imported recipes (`standard-lunch`); a UUID string for new ones.
    public var id: String
    public var name: String
    /// "1 bar (55 g)", "1 lunch".
    public var serving: String
    public var category: String?
    public var macros: NutritionMacros
    public var parts: [NutritionRecipePart]
    public var notes: String
    /// The text the estimate was made from, kept so it can be re-estimated.
    public var sourceText: String?
    /// Made while logging a day: hidden from the list and picker, found by search, promoted on reuse.
    public var oneOff: Bool
    public var archived: Bool
    /// Unix seconds.
    public var createdAt: Int
    public var updatedAt: Int
    public var lastUsedTs: Int?

    public init(id: String, name: String, serving: String, category: String? = nil, macros: NutritionMacros,
                parts: [NutritionRecipePart] = [], notes: String = "", sourceText: String? = nil,
                oneOff: Bool = false, archived: Bool = false, createdAt: Int, updatedAt: Int, lastUsedTs: Int? = nil) {
        self.id = id; self.name = name; self.serving = serving; self.category = category; self.macros = macros
        self.parts = parts; self.notes = notes; self.sourceText = sourceText; self.oneOff = oneOff
        self.archived = archived; self.createdAt = createdAt; self.updatedAt = updatedAt; self.lastUsedTs = lastUsedTs
    }
}

/// One planned slot of the standard day, or one row of a stored day.
public struct NutritionItem: Equatable, Codable, Sendable, Identifiable {
    public var id: String
    /// "Lunch", "Dinner — main".
    public var label: String
    /// When it is eaten, minutes after local midnight; nil when unknown (old imported rows).
    public var minuteOfDay: Int?
    public var recipeId: String
    /// Servings: 0.5, 1, 1.5, 2…
    public var portion: Double
    /// Standard-day slots only: recipes offered first when swapping this slot.
    public var swaps: [String]

    public init(id: String = UUID().uuidString, label: String, minuteOfDay: Int?, recipeId: String,
                portion: Double = 1, swaps: [String] = []) {
        self.id = id; self.label = label; self.minuteOfDay = minuteOfDay; self.recipeId = recipeId
        self.portion = portion; self.swaps = swaps
    }
}

/// How a day's food is known.
public enum NutritionDayState: String, Codable, Sendable {
    /// No stored row: the day is the standard day as it stood on that date.
    case standard
    /// The day has its own rows (edited, or imported history).
    case edited
    /// Marked "didn't track": no data, never the standard.
    case untracked
    /// Before tracking began (earlier than the first standard version) and nothing stored.
    case none
}

/// A day's food after resolution.
public struct NutritionDay: Equatable, Sendable {
    public var day: String
    public var state: NutritionDayState
    public var items: [NutritionItem]
    /// Unix seconds; set once the day is final (journal finished or the following day ended).
    public var lockedAt: Int?

    public init(day: String, state: NutritionDayState, items: [NutritionItem], lockedAt: Int? = nil) {
        self.day = day; self.state = state; self.items = items; self.lockedAt = lockedAt
    }

    /// Totals of the items whose recipe is known; a missing recipe contributes nothing.
    public func totals(recipes: [String: NutritionRecipe]) -> NutritionMacros {
        NutritionMacros.sum(items.compactMap { item in recipes[item.recipeId].map { $0.macros.scaled(item.portion) } })
    }
}

// MARK: - Pure resolution

public enum NutritionResolve {
    /// The standard version in force on `day` ("yyyy-MM-dd"): the latest whose effective day is on or
    /// before it. Versions are (effectiveDay, createdAt, slots); a later save on the same day wins.
    public static func standardSlots(on day: String,
                                     versions: [(effectiveDay: String, createdAt: Int, slots: [NutritionItem])]) -> [NutritionItem]? {
        versions
            .filter { $0.effectiveDay <= day }
            .max { ($0.effectiveDay, $0.createdAt) < ($1.effectiveDay, $1.createdAt) }?
            .slots
    }

    /// One day's food: stored rows win; otherwise the standard day in force then; before the first
    /// version, nothing.
    public static func day(_ day: String, stored: (state: NutritionDayState, items: [NutritionItem], lockedAt: Int?)?,
                           versions: [(effectiveDay: String, createdAt: Int, slots: [NutritionItem])]) -> NutritionDay {
        if let stored {
            return NutritionDay(day: day, state: stored.state, items: stored.state == .untracked ? [] : stored.items,
                                lockedAt: stored.lockedAt)
        }
        guard let slots = standardSlots(on: day, versions: versions) else {
            return NutritionDay(day: day, state: .none, items: [])
        }
        return NutritionDay(day: day, state: .standard, items: slots)
    }
}

// MARK: - Store

extension WhoopStore {

    /// Create the nutrition tables if they are missing. Idempotent and cheap; call before the first read.
    public func ensureNutritionSchema() async throws {
        try syncWrite { db in
            let macroColumns: (TableDefinition) -> Void = { t in
                t.column("kcal", .double).notNull().defaults(to: 0)
                t.column("proteinG", .double).notNull().defaults(to: 0)
                t.column("carbsG", .double).notNull().defaults(to: 0)
                t.column("fiberG", .double).notNull().defaults(to: 0)
                t.column("sugarG", .double).notNull().defaults(to: 0)
                t.column("fatG", .double).notNull().defaults(to: 0)
                t.column("satFatG", .double).notNull().defaults(to: 0)
                t.column("sodiumMg", .double)
            }
            try db.create(table: "nutritionRecipe", options: [.ifNotExists]) { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("serving", .text).notNull()
                t.column("category", .text)
                macroColumns(t)
                t.column("notes", .text).notNull().defaults(to: "")
                t.column("sourceText", .text)
                t.column("oneOff", .integer).notNull().defaults(to: 0)
                t.column("archived", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .integer).notNull()
                t.column("updatedAt", .integer).notNull()
                t.column("lastUsedTs", .integer)
            }
            try db.create(table: "nutritionRecipePart", options: [.ifNotExists]) { t in
                t.column("recipeId", .text).notNull()
                t.column("ord", .integer).notNull()
                t.column("name", .text).notNull()
                macroColumns(t)
                t.primaryKey(["recipeId", "ord"])
            }
            // One row per save of the standard day. `effectiveDay` is the first day it applies to.
            try db.create(table: "nutritionStandardVersion", options: [.ifNotExists]) { t in
                t.column("id", .text).primaryKey()
                t.column("effectiveDay", .text).notNull()
                t.column("createdAt", .integer).notNull()
            }
            try db.create(table: "nutritionStandardSlot", options: [.ifNotExists]) { t in
                t.column("id", .text).primaryKey()
                t.column("versionId", .text).notNull()
                t.column("ord", .integer).notNull()
                t.column("label", .text).notNull()
                t.column("minuteOfDay", .integer)
                t.column("recipeId", .text).notNull()
                t.column("portion", .double).notNull().defaults(to: 1)
                t.column("swaps", .text)   // comma-joined recipe ids
            }
            try db.create(index: "idx_nutritionStandardSlot_version", on: "nutritionStandardSlot",
                          columns: ["versionId", "ord"], options: [.ifNotExists])
            // A day only gets a row once it differs from the standard (edited / untracked) or is locked.
            try db.create(table: "nutritionDay", options: [.ifNotExists]) { t in
                t.column("day", .text).primaryKey()          // yyyy-MM-dd, local
                t.column("state", .text).notNull()           // edited | untracked | standard (locked only)
                t.column("lockedAt", .integer)
                t.column("updatedAt", .integer).notNull()
            }
            try db.create(table: "nutritionDayItem", options: [.ifNotExists]) { t in
                t.column("id", .text).primaryKey()
                t.column("day", .text).notNull()
                t.column("ord", .integer).notNull()
                t.column("label", .text).notNull()
                t.column("minuteOfDay", .integer)
                t.column("recipeId", .text).notNull()
                t.column("portion", .double).notNull().defaults(to: 1)
            }
            try db.create(index: "idx_nutritionDayItem_day", on: "nutritionDayItem",
                          columns: ["day", "ord"], options: [.ifNotExists])
            try db.create(table: "nutritionMeta", options: [.ifNotExists]) { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text)
            }
        }
    }

    // MARK: Recipes

    /// Insert or replace recipes (and their parts) by id.
    @discardableResult
    public func upsertNutritionRecipes(_ recipes: [NutritionRecipe]) async throws -> Int {
        guard !recipes.isEmpty else { return 0 }
        return try syncWrite { db in
            for r in recipes { try Self.writeRecipe(r, db: db) }
            return recipes.count
        }
    }

    private static func writeRecipe(_ r: NutritionRecipe, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO nutritionRecipe
                (id, name, serving, category, kcal, proteinG, carbsG, fiberG, sugarG, fatG, satFatG, sodiumMg,
                 notes, sourceText, oneOff, archived, createdAt, updatedAt, lastUsedTs)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name, serving = excluded.serving, category = excluded.category,
                kcal = excluded.kcal, proteinG = excluded.proteinG, carbsG = excluded.carbsG,
                fiberG = excluded.fiberG, sugarG = excluded.sugarG, fatG = excluded.fatG,
                satFatG = excluded.satFatG, sodiumMg = excluded.sodiumMg, notes = excluded.notes,
                sourceText = excluded.sourceText, oneOff = excluded.oneOff, archived = excluded.archived,
                updatedAt = excluded.updatedAt,
                lastUsedTs = CASE WHEN excluded.lastUsedTs IS NULL THEN lastUsedTs
                                  WHEN lastUsedTs IS NULL THEN excluded.lastUsedTs
                                  ELSE MAX(excluded.lastUsedTs, lastUsedTs) END
            """, arguments: StatementArguments(
                [r.id, r.name, r.serving, r.category] + r.macros.arguments +
                [r.notes, r.sourceText, r.oneOff ? 1 : 0, r.archived ? 1 : 0, r.createdAt, r.updatedAt, r.lastUsedTs]))
        try db.execute(sql: "DELETE FROM nutritionRecipePart WHERE recipeId = ?", arguments: [r.id])
        for (i, p) in r.parts.enumerated() {
            try db.execute(sql: """
                INSERT INTO nutritionRecipePart
                    (recipeId, ord, name, kcal, proteinG, carbsG, fiberG, sugarG, fatG, satFatG, sodiumMg)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: StatementArguments([r.id, i, p.name] + p.macros.arguments))
        }
    }

    /// Every recipe (one-offs and archived included), keyed by id.
    public func nutritionRecipes() async throws -> [String: NutritionRecipe] {
        try syncRead { db in
            var parts: [String: [NutritionRecipePart]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM nutritionRecipePart ORDER BY recipeId, ord") {
                parts[row["recipeId"], default: []].append(NutritionRecipePart(name: row["name"], macros: NutritionMacros(row: row)))
            }
            var out: [String: NutritionRecipe] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM nutritionRecipe") {
                let id: String = row["id"]
                out[id] = NutritionRecipe(
                    id: id, name: row["name"], serving: row["serving"], category: row["category"],
                    macros: NutritionMacros(row: row), parts: parts[id] ?? [], notes: row["notes"],
                    sourceText: row["sourceText"], oneOff: (row["oneOff"] as Int) != 0,
                    archived: (row["archived"] as Int) != 0, createdAt: row["createdAt"],
                    updatedAt: row["updatedAt"], lastUsedTs: row["lastUsedTs"])
            }
            return out
        }
    }

    @discardableResult
    public func deleteNutritionRecipe(id: String) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM nutritionRecipePart WHERE recipeId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM nutritionRecipe WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }

    /// Mark recipes as used now (recency for the picker). Using a one-off again makes it a regular recipe.
    public func touchNutritionRecipes(ids: [String], at ts: Int, promoteOneOffs: Bool) async throws {
        guard !ids.isEmpty else { return }
        try syncWrite { db in
            for id in ids {
                try db.execute(sql: """
                    UPDATE nutritionRecipe SET lastUsedTs = ?, oneOff = CASE WHEN ? THEN 0 ELSE oneOff END
                    WHERE id = ?
                    """, arguments: [ts, promoteOneOffs, id])
            }
        }
    }

    // MARK: Standard day

    /// Save a new version of the standard day, in force from `effectiveDay`.
    public func saveNutritionStandard(slots: [NutritionItem], effectiveDay: String, createdAt: Int) async throws {
        try syncWrite { db in try Self.writeStandard(slots: slots, effectiveDay: effectiveDay, createdAt: createdAt, db: db) }
    }

    private static func writeStandard(slots: [NutritionItem], effectiveDay: String, createdAt: Int, db: Database) throws {
        let versionId = UUID().uuidString
        try db.execute(sql: "INSERT INTO nutritionStandardVersion (id, effectiveDay, createdAt) VALUES (?, ?, ?)",
                       arguments: [versionId, effectiveDay, createdAt])
        for (i, s) in slots.enumerated() {
            try db.execute(sql: """
                INSERT INTO nutritionStandardSlot (id, versionId, ord, label, minuteOfDay, recipeId, portion, swaps)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, versionId, i, s.label, s.minuteOfDay, s.recipeId, s.portion,
                                 s.swaps.isEmpty ? nil : s.swaps.joined(separator: ",")])
        }
    }

    /// Every standard version, for `NutritionResolve`.
    public func nutritionStandardVersions() async throws -> [(effectiveDay: String, createdAt: Int, slots: [NutritionItem])] {
        try syncRead { db in
            var slots: [String: [NutritionItem]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM nutritionStandardSlot ORDER BY versionId, ord") {
                let swaps: String? = row["swaps"]
                slots[row["versionId"], default: []].append(NutritionItem(
                    id: row["id"], label: row["label"], minuteOfDay: row["minuteOfDay"], recipeId: row["recipeId"],
                    portion: row["portion"], swaps: swaps?.split(separator: ",").map(String.init) ?? []))
            }
            return try Row.fetchAll(db, sql: "SELECT * FROM nutritionStandardVersion").map { row in
                (effectiveDay: row["effectiveDay"], createdAt: row["createdAt"], slots: slots[row["id"]] ?? [])
            }
        }
    }

    // MARK: Days

    /// The stored rows for days in [from, to] (inclusive, yyyy-MM-dd). Days without a row are absent.
    public func nutritionStoredDays(from: String, to: String) async throws
        -> [String: (state: NutritionDayState, items: [NutritionItem], lockedAt: Int?)] {
        try syncRead { db in
            var items: [String: [NutritionItem]] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT * FROM nutritionDayItem WHERE day BETWEEN ? AND ? ORDER BY day, ord
                """, arguments: [from, to]) {
                items[row["day"], default: []].append(NutritionItem(
                    id: row["id"], label: row["label"], minuteOfDay: row["minuteOfDay"],
                    recipeId: row["recipeId"], portion: row["portion"]))
            }
            var out: [String: (state: NutritionDayState, items: [NutritionItem], lockedAt: Int?)] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM nutritionDay WHERE day BETWEEN ? AND ?",
                                        arguments: [from, to]) {
                let day: String = row["day"]
                let state = NutritionDayState(rawValue: row["state"]) ?? .edited
                // A locked-but-unedited day is stored only for its lock; it still reads as the standard.
                if state == .standard { continue }
                out[day] = (state, items[day] ?? [], row["lockedAt"])
            }
            return out
        }
    }

    /// Lock times for days in [from, to], including locked days that are still the standard.
    public func nutritionLocks(from: String, to: String) async throws -> [String: Int] {
        try syncRead { db in
            var out: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT day, lockedAt FROM nutritionDay WHERE day BETWEEN ? AND ? AND lockedAt IS NOT NULL
                """, arguments: [from, to]) { out[row["day"]] = row["lockedAt"] }
            return out
        }
    }

    /// Give a day its own rows (its first edit, or any later one). Keeps an existing lock.
    public func saveNutritionDay(_ day: String, items: [NutritionItem], at ts: Int) async throws {
        try syncWrite { db in try Self.writeDay(day, state: .edited, items: items, at: ts, db: db) }
    }

    /// Mark a day "didn't track" (no data) or, with `false`, put it back to following the standard.
    public func setNutritionDayUntracked(_ day: String, _ untracked: Bool, at ts: Int) async throws {
        try syncWrite { db in
            if untracked {
                try Self.writeDay(day, state: .untracked, items: [], at: ts, db: db)
            } else {
                try db.execute(sql: "DELETE FROM nutritionDayItem WHERE day = ?", arguments: [day])
                try db.execute(sql: "UPDATE nutritionDay SET state = 'standard', updatedAt = ? WHERE day = ?",
                               arguments: [ts, day])
                try db.execute(sql: "DELETE FROM nutritionDay WHERE day = ? AND lockedAt IS NULL", arguments: [day])
            }
        }
    }

    /// Lock a day as final. An unedited day gets a row holding only the lock.
    public func lockNutritionDay(_ day: String, at ts: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO nutritionDay (day, state, lockedAt, updatedAt) VALUES (?, 'standard', ?, ?)
                ON CONFLICT(day) DO UPDATE SET lockedAt = COALESCE(lockedAt, excluded.lockedAt)
                """, arguments: [day, ts, ts])
        }
    }

    private static func writeDay(_ day: String, state: NutritionDayState, items: [NutritionItem], at ts: Int,
                                 db: Database) throws {
        try db.execute(sql: """
            INSERT INTO nutritionDay (day, state, lockedAt, updatedAt) VALUES (?, ?, NULL, ?)
            ON CONFLICT(day) DO UPDATE SET state = excluded.state, updatedAt = excluded.updatedAt
            """, arguments: [day, state.rawValue, ts])
        try db.execute(sql: "DELETE FROM nutritionDayItem WHERE day = ?", arguments: [day])
        for (i, item) in items.enumerated() {
            try db.execute(sql: """
                INSERT INTO nutritionDayItem (id, day, ord, label, minuteOfDay, recipeId, portion)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [item.id, day, i, item.label, item.minuteOfDay, item.recipeId, item.portion])
        }
    }

    // MARK: Import

    /// Apply a vault import in one transaction: recipes upserted by id (so re-importing updates rather
    /// than duplicates), a new standard version (skipped when it matches the one in force on its day), and
    /// the history days replaced — except days already edited in the app, which are left alone.
    public func importNutrition(recipes: [NutritionRecipe], standard: (effectiveDay: String, slots: [NutritionItem])?,
                                days: [(day: String, state: NutritionDayState, items: [NutritionItem])],
                                at ts: Int) async throws -> (recipes: Int, days: Int, skippedDays: Int) {
        let versions = try await nutritionStandardVersions()
        return try syncWrite { db in
            for r in recipes { try Self.writeRecipe(r, db: db) }
            if let standard {
                let current = NutritionResolve.standardSlots(on: standard.effectiveDay, versions: versions)
                let same = current.map { cur in
                    cur.map { [$0.label, $0.recipeId, "\($0.portion)", "\($0.minuteOfDay ?? -1)"] } ==
                    standard.slots.map { [$0.label, $0.recipeId, "\($0.portion)", "\($0.minuteOfDay ?? -1)"] }
                } ?? false
                if !same { try Self.writeStandard(slots: standard.slots, effectiveDay: standard.effectiveDay, createdAt: ts, db: db) }
            }
            var written = 0, skipped = 0
            let lastImport = try Self.importStamp(db: db)
            for d in days {
                let existing = try Row.fetchOne(db, sql: "SELECT updatedAt FROM nutritionDay WHERE day = ? AND state != 'standard'",
                                                arguments: [d.day])
                // A day edited in the app after a previous import wins over the vault copy.
                if let existing, (existing["updatedAt"] as Int) > lastImport { skipped += 1; continue }
                try Self.writeDay(d.day, state: d.state, items: d.items, at: ts, db: db)
                written += 1
            }
            try db.execute(sql: "INSERT OR REPLACE INTO nutritionMeta (key, value) VALUES ('lastImportAt', ?)",
                           arguments: ["\(ts)"])
            return (recipes.count, written, skipped)
        }
    }

    /// When the last import ran; `Int.max` before the first, so nothing counts as edited since.
    private static func importStamp(db: Database) throws -> Int {
        return Int(try String.fetchOne(db, sql: "SELECT value FROM nutritionMeta WHERE key = 'lastImportAt'") ?? "") ?? Int.max
    }
}
