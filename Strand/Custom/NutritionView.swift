import SwiftUI
import StrandDesign
import WhoopStore

// nikhil/custom — the Nutrition screen: today's bars and food, the evening top-up, and the way into the
// standard day, the recipes and the plan's numbers.
struct NutritionView: View {
    @EnvironmentObject private var repo: Repository
    @ObservedObject private var changes = NutritionChanges.shared
    @State private var snapshot: NutritionTodayCard.Snapshot?
    @State private var topUps: [NutritionRecipe] = []
    @State private var showPlan = false

    private var todayKey: String { Repository.localDayKey(Date()) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                NutritionTodayCard(linksToScreen: false)
                section("Today's food") { NutritionDayEditor(mode: .day(todayKey)) }
                topUpSection
                section("More") {
                    VStack(alignment: .leading, spacing: 0) {
                        NavigationLink { NutritionStandardView() } label: { linkRow("Standard day", "calendar") }
                        Divider()
                        NavigationLink { NutritionRecipesView() } label: { linkRow("Recipes", "book") }
                        Divider()
                        Button { showPlan = true } label: { linkRow("Targets and burn", "target") }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(NoopMetrics.screenPadding)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle("Nutrition")
        .task(id: changes.seq) { await reloadTopUps() }
        .sheet(isPresented: $showPlan) { NutritionPlanSheet() }
    }

    // MARK: Evening top-up

    @ViewBuilder private var topUpSection: some View {
        if let s = snapshot, s.balance.spare >= 50 {
            section("Room to top up") {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    if Calendar.current.component(.hour, from: Date()) >= 21 {
                        Text("It's past 9 PM: the \(Int(s.balance.spare.rounded())) kcal goes to this week's ledger.")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    } else {
                        Text("\(Int(s.balance.spare.rounded())) kcal to spare. Protein and fibre first:")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        ForEach(topUps) { r in
                            Button {
                                Task {
                                    await repo.editNutritionDay(todayKey) { rows in
                                        let now = Date()
                                        let minute = Calendar.current.component(.hour, from: now) * 60
                                            + Calendar.current.component(.minute, from: now)
                                        rows.append(NutritionItem(label: String(localized: "Top-up"), minuteOfDay: minute, recipeId: r.id))
                                    }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle.fill").foregroundStyle(StrandPalette.accent)
                                    Text(r.name).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                                    Spacer()
                                    Text("\(Int(r.macros.kcal.rounded())) kcal · \(Int(r.macros.proteinG.rounded())) g P")
                                        .font(StrandFont.caption).monospacedDigit().foregroundStyle(StrandPalette.textSecondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func reloadTopUps() async {
        snapshot = await NutritionTodayCard.load(repo)
        let spare = snapshot?.balance.spare ?? 0
        let recipes = await repo.nutritionRecipeList().values
        topUps = Self.topUps(Array(recipes), spare: spare)
    }

    /// Regular recipes that fit in `spare`, best protein + fibre per kcal first.
    static func topUps(_ recipes: [NutritionRecipe], spare: Double, limit: Int = 6) -> [NutritionRecipe] {
        recipes.filter { !$0.oneOff && !$0.archived && $0.macros.kcal >= 30 && $0.macros.kcal <= spare }
            .sorted { a, b in
                let sa = (a.macros.proteinG + a.macros.fiberG) / a.macros.kcal
                let sb = (b.macros.proteinG + b.macros.fiberG) / b.macros.kcal
                return sa == sb ? a.name < b.name : sa > sb
            }
            .prefix(limit).map { $0 }
    }

    // MARK: Pieces

    private func section<V: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(title).strandOverline()
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoopPanelSurface(cornerRadius: 18))
    }

    private func linkRow(_ title: LocalizedStringKey, _ icon: String) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(StrandPalette.accent).frame(width: 24)
            Text(title).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// The standard day: the rows every untouched day copies. Saving makes a new version from today.
struct NutritionStandardView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Every day starts as this list until you edit that day. Changes apply from today; past days keep the standard they had.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                NutritionDayEditor(mode: .standard)
            }
            .padding(NoopMetrics.screenPadding)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle("Standard day")
    }
}

/// Every regular recipe (one-offs behind a toggle), tap to edit, + for a new one.
struct NutritionRecipesView: View {
    @EnvironmentObject private var repo: Repository
    @ObservedObject private var changes = NutritionChanges.shared
    @State private var recipes: [NutritionRecipe] = []
    @State private var showOneOffs = false
    @State private var query = ""
    @State private var editing: NutritionRecipe?
    @State private var creating = false

    var body: some View {
        List {
            Toggle("Show one-offs", isOn: $showOneOffs).tint(StrandPalette.accent)
            ForEach(filtered) { r in
                Button { editing = r } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            Text(r.oneOff ? "\(r.serving) · one-off" : r.serving)
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                        Spacer()
                        Text("\(Int(r.macros.kcal.rounded())) kcal")
                            .font(StrandFont.caption).monospacedDigit().foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .swipeActions {
                    if r.oneOff {
                        Button("Keep") { Task { var k = r; k.oneOff = false; await repo.saveNutritionRecipe(k) } }
                            .tint(StrandPalette.accent)
                    }
                    Button(r.archived ? "Restore" : "Archive") {
                        Task { var k = r; k.archived.toggle(); await repo.saveNutritionRecipe(k) }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search recipes")
        .navigationTitle("Recipes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Image(systemName: "plus") }
            }
        }
        .task(id: changes.seq) { recipes = await repo.nutritionRecipeList().values.sorted { $0.name < $1.name } }
        .sheet(item: $editing) { r in
            NutritionEstimateSheet(oneOff: r.oneOff, editing: r) { _ in editing = nil }.environmentObject(repo)
        }
        .sheet(isPresented: $creating) {
            NutritionEstimateSheet(oneOff: false) { _ in creating = false }.environmentObject(repo)
        }
    }

    private var filtered: [NutritionRecipe] {
        let q = query.lowercased()
        return recipes.filter { (showOneOffs || !$0.oneOff) && (q.isEmpty || $0.name.lowercased().contains(q)) }
    }
}

/// The plan's numbers: the balance target, resting burn and digestion share.
struct NutritionPlanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var target = NutritionPlan.targetBalance
    @State private var rmr = NutritionPlan.rmrKcal
    @State private var tef = NutritionPlan.tefPercent

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $target, in: NutritionPlan.targetRange, step: 50) {
                        row("Daily target", NutritionTodayCard.signed(Double(target)) + " kcal")
                    }
                } footer: {
                    Text("Negative is a deficit. The week's target is seven times this, Monday to Sunday.")
                }
                Section {
                    Stepper(value: $rmr, in: 800...3000, step: 1) { row("Resting burn (RMR)", "\(rmr) kcal") }
                    Stepper(value: $tef, in: 0...20, step: 1) { row("Digestion (TEF)", "\(tef)% of intake") }
                } footer: {
                    Text("Calories out = resting burn for the whole day + digestion + active energy so far (the average of Apple Health and the strap).")
                }
            }
            .navigationTitle("Targets and burn")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let d = UserDefaults.standard
                        d.set(target, forKey: NutritionPlan.targetKey)
                        d.set(rmr, forKey: NutritionPlan.rmrKey)
                        d.set(tef, forKey: NutritionPlan.tefKey)
                        NutritionChanges.shared.bump()
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 360)
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).monospacedDigit().foregroundStyle(StrandPalette.textSecondary) }
    }
}
