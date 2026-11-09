import SwiftUI
import StrandDesign
import WhoopStore

// nikhil/custom — choose a recipe for a row: the slot's swap options first, then recently used, then the
// rest; one-offs only through search. "New from text or photo" estimates a new one (saved as a one-off when
// it is made from here).
struct NutritionRecipePicker: View {
    let recipes: [String: NutritionRecipe]
    /// Offered first (a slot's swap options).
    let preferred: [String]
    let title: LocalizedStringKey
    /// The chosen recipe id, and whether it was created just now.
    let onPick: (String, Bool) -> Void

    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var creating = false

    private var matches: [NutritionRecipe] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let pool = recipes.values.filter { !$0.archived }
        if q.isEmpty {
            let preferredSet = Set(preferred)
            return pool.filter { !$0.oneOff && !preferredSet.contains($0.id) }
                .sorted { ($0.lastUsedTs ?? 0, $1.name) > ($1.lastUsedTs ?? 0, $0.name) }
        }
        return pool.filter { $0.name.lowercased().contains(q) || $0.id.contains(q) }
            .sorted { ($0.oneOff ? 1 : 0, $0.name) < ($1.oneOff ? 1 : 0, $1.name) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { creating = true } label: {
                        Label("New from text or photo", systemImage: "sparkles")
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
                let firsts = query.isEmpty ? preferred.compactMap { recipes[$0] } : []
                if !firsts.isEmpty {
                    Section("For this slot") { ForEach(firsts) { pickRow($0) } }
                }
                Section(query.isEmpty ? "Recipes" : "Matches") { ForEach(matches) { pickRow($0) } }
            }
            .searchable(text: $query, prompt: "Search recipes")
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(isPresented: $creating) {
                NutritionEstimateSheet(initialText: query, oneOff: true) { recipe in
                    creating = false
                    onPick(recipe.id, true)
                }
                .environmentObject(repo)
            }
        }
        .frame(minWidth: 360, minHeight: 480)
    }

    private func pickRow(_ r: NutritionRecipe) -> some View {
        Button { onPick(r.id, false) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.name).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text(r.oneOff ? "\(r.serving) · one-off" : r.serving)
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
                Text("\(Int(r.macros.kcal.rounded())) kcal · \(Int(r.macros.proteinG.rounded())) g P")
                    .font(StrandFont.caption).monospacedDigit().foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
}

/// The + menu's "Add food": pick (or make) a recipe and it is added to today, then the sheet closes.
struct NutritionQuickAdd: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var recipes: [String: NutritionRecipe]?

    var body: some View {
        Group {
            if let recipes {
                NutritionRecipePicker(recipes: recipes, preferred: [], title: "Add food") { id, justCreated in
                    Task {
                        let now = Date()
                        let minute = Calendar.current.component(.hour, from: now) * 60 + Calendar.current.component(.minute, from: now)
                        await repo.editNutritionDay(Repository.localDayKey(now), justCreated: justCreated ? [id] : []) { rows in
                            rows.append(NutritionItem(label: String(localized: "Added"), minuteOfDay: minute, recipeId: id))
                            rows.sort { ($0.minuteOfDay ?? 0) < ($1.minuteOfDay ?? 0) }
                        }
                        dismiss()
                    }
                }
            } else {
                ProgressView()
            }
        }
        .task { recipes = await repo.nutritionRecipeList() }
    }
}
