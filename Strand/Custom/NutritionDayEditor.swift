import SwiftUI
import StrandDesign
import WhoopStore

// nikhil/custom — one day's food, editable: rows by meal slot, each with swap / portion / remove, plus Add
// food and "Didn't track". The Nutrition screen shows today with it; the journal shows yesterday.
// In `.standard` mode it edits the standard day itself and saves a new dated version.
struct NutritionDayEditor: View {
    enum Mode: Equatable { case day(String), standard }

    let mode: Mode
    @EnvironmentObject private var repo: Repository
    @ObservedObject private var changes = NutritionChanges.shared
    @State private var items: [NutritionItem] = []
    @State private var state: NutritionDayState = .standard
    @State private var standardSlots: [NutritionItem] = []
    @State private var recipes: [String: NutritionRecipe] = [:]
    @State private var picking: Picking?
    @State private var loaded = false
    /// The recipe opened by tapping a row.
    @State private var openRecipe: NutritionRecipe?

    /// What the recipe picker is choosing for.
    struct Picking: Identifiable {
        let id = UUID()
        /// Nil adds a row; otherwise the row being swapped.
        let rowId: String?
        let swaps: [String]
    }

    private var dayKey: String {
        if case .day(let key) = mode { return key }
        return Repository.localDayKey(Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            if state == .untracked {
                Text("Marked as not tracked: this day counts as no data.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            } else if state == .none && items.isEmpty {
                Text("No standard day yet. Import your vault file in Settings, or add food below.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
            ForEach(items) { item in row(item) }
            HStack(spacing: NoopMetrics.space3) {
                Button { picking = Picking(rowId: nil, swaps: []) } label: {
                    Label("Add food", systemImage: "plus")
                }
                .buttonStyle(NoopButtonStyle(.secondary))
                Spacer()
                if case .day = mode {
                    Button(state == .untracked ? "Track this day" : "Didn't track") {
                        Task {
                            await repo.setNutritionDayUntracked(dayKey, state != .untracked)
                            await reload()
                        }
                    }
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, NoopMetrics.space2)
        }
        .task(id: "\(changes.seq)-\(dayKey)") { await reload() }
        .sheet(item: $picking) { p in
            NutritionRecipePicker(recipes: recipes, preferred: p.swaps,
                                  title: p.rowId == nil ? "Add food" : "Swap") { recipeId, justCreated in
                picking = nil
                Task { await apply(p, recipeId: recipeId, justCreated: justCreated) }
            }
            .environmentObject(repo)
        }
        .sheet(item: $openRecipe) { r in
            NutritionEstimateSheet(oneOff: r.oneOff, editing: r) { _ in openRecipe = nil }
                .environmentObject(repo)
        }
    }

    // MARK: Rows

    private func row(_ item: NutritionItem) -> some View {
        let recipe = recipes[item.recipeId]
        let kcal = (recipe?.macros.kcal ?? 0) * item.portion
        let protein = (recipe?.macros.proteinG ?? 0) * item.portion
        let slot = standardSlots.first { $0.id == item.id }
        return HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            // Tapping the row (not the ••• menu) opens its recipe: parts, numbers, notes, editable.
            Button { openRecipe = recipe } label: { rowText(item, recipe: recipe, kcal: kcal, protein: protein) }
                .buttonStyle(.plain)
                .disabled(recipe == nil)
            Menu {
                Button { openRecipe = recipe } label: { Label("Open recipe", systemImage: "book") }
                    .disabled(recipe == nil)
                Button { picking = Picking(rowId: item.id, swaps: slot?.swaps ?? []) } label: {
                    Label("Swap", systemImage: "arrow.left.arrow.right")
                }
                Menu {
                    ForEach([0.5, 1, 1.5, 2, 3], id: \.self) { p in
                        Button(Self.portionLabel(p)) { Task { await edit { rows in Self.setPortion(&rows, item.id, p) } } }
                    }
                } label: { Label("Portion", systemImage: "slider.horizontal.3") }
                Button(role: .destructive) {
                    Task { await edit { rows in rows.removeAll { $0.id == item.id } } }
                } label: { Label("Remove", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(StrandPalette.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }

    private func rowText(_ item: NutritionItem, recipe: NutritionRecipe?, kcal: Double, protein: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                Text(Self.portionPrefix(item.portion) + (recipe?.name ?? item.recipeId))
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(kcal.rounded())) kcal").font(StrandFont.subhead).monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("\(Int(protein.rounded())) g protein").font(StrandFont.caption).monospacedDigit()
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .contentShape(Rectangle())
    }

    static func portionPrefix(_ p: Double) -> String { p == 1 ? "" : portionLabel(p) + " " }

    static func portionLabel(_ p: Double) -> String {
        switch p {
        case 0.5: return "½"
        case 1.5: return "1½"
        case 0.25: return "¼"
        default: return p == p.rounded() ? "\(Int(p))×" : String(format: "%.2g×", p)
        }
    }

    static func setPortion(_ rows: inout [NutritionItem], _ id: String, _ portion: Double) {
        if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].portion = portion }
    }

    // MARK: Changes

    private func apply(_ p: Picking, recipeId: String, justCreated: Bool) async {
        let created: Set<String> = justCreated ? [recipeId] : []
        if let rowId = p.rowId {
            await edit(justCreated: created) { rows in
                if let i = rows.firstIndex(where: { $0.id == rowId }) { rows[i].recipeId = recipeId }
            }
        } else {
            let now = Date()
            let minute = Calendar.current.component(.hour, from: now) * 60 + Calendar.current.component(.minute, from: now)
            await edit(justCreated: created) { rows in
                rows.append(NutritionItem(label: String(localized: "Added"), minuteOfDay: minute, recipeId: recipeId))
                rows.sort { ($0.minuteOfDay ?? 0) < ($1.minuteOfDay ?? 0) }
            }
        }
    }

    private func edit(justCreated: Set<String> = [], _ change: @escaping (inout [NutritionItem]) -> Void) async {
        switch mode {
        case .day(let key):
            await repo.editNutritionDay(key, justCreated: justCreated, change)
        case .standard:
            var rows = items
            change(&rows)
            await repo.saveNutritionStandard(rows)
        }
        await reload()
    }

    private func reload() async {
        recipes = await repo.nutritionRecipeList()
        standardSlots = await repo.nutritionStandardSlots(on: dayKey)
        switch mode {
        case .day(let key):
            let day = await repo.nutritionDay(key)
            items = day.items
            state = day.state
        case .standard:
            items = standardSlots
            state = .standard
        }
        loaded = true
    }
}
