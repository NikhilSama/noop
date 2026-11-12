import SwiftUI
import StrandDesign
import WhoopStore

// nikhil/custom — the Nutrition screen's macro rings: protein, fibre, carbs, sugar, unsaturated and
// saturated fat for today's food (the whole planned day, like the IN bar) against `NutritionMacro` targets.
// A ring fills toward its target in the accent colour, then reads green once a min is reached or an aim
// landed; a max goes yellow from 85 % and red past it. Under them, "What should I eat?" opens the advice.
struct NutritionMacroRings: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var coach: AICoachEngine
    @ObservedObject private var changes = NutritionChanges.shared
    @State private var totals: NutritionMacros = .zero
    @State private var asking = false

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: NoopMetrics.space2), count: 3),
                      spacing: NoopMetrics.space3) {
                ForEach(NutritionMacro.allCases) { ring($0) }
            }
            Button { asking = true } label: {
                Label("What should I eat?", systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .buttonStyle(NoopButtonStyle(.primary))
            .disabled(!coach.isConfigured)
            if !coach.isConfigured {
                Text("Set up the Coach with a key to get suggestions.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .task(id: changes.seq) { await reload() }
        .sheet(isPresented: $asking) { NutritionAdviceSheet().environmentObject(repo).environmentObject(coach) }
    }

    private func reload() async {
        let day = await repo.nutritionDay(Repository.localDayKey(Date()))
        let recipes = await repo.nutritionRecipeList()
        totals = NutritionMacro.totals(day.state == .untracked ? [] : day.items, recipes: recipes)
    }

    private func ring(_ m: NutritionMacro) -> some View {
        let v = m.grams(totals)
        let t = Double(m.target)
        let status = m.status(v, target: t)
        return VStack(spacing: 4) {
            ZStack {
                Circle().stroke(StrandPalette.textTertiary.opacity(0.15), lineWidth: 7)
                Circle().trim(from: 0, to: min(v / max(t, 0.1), 1))
                    .stroke(status.color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(v < 10 ? String(format: "%.1f", v) : "\(Int(v.rounded()))")
                    .font(StrandFont.subhead.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(status == .over ? StrandPalette.statusCritical : StrandPalette.textPrimary)
            }
            .frame(width: 62, height: 62)
            Text(m.title).font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
            Text("\(m.kindWord) \(m.target) g").font(StrandFont.caption).monospacedDigit()
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(m.title): \(Int(v.rounded())) grams, \(m.kindWord) \(m.target)"))
    }
}

/// The advice: asks as soon as it opens; a note ("craving something sweet", "eating out") and Ask again
/// refine it. A library suggestion has Add, which puts it on today at that portion.
struct NutritionAdviceSheet: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var coach: AICoachEngine
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var advice: NutritionAdvisor.Advice?
    @State private var error: String?
    @State private var running = false
    @State private var added: Set<Int> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    if running && advice == nil {
                        HStack(spacing: NoopMetrics.space2) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    if let error {
                        Text(error).font(StrandFont.subhead).foregroundStyle(StrandPalette.statusWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let advice {
                        if !advice.summary.isEmpty {
                            Text(advice.summary).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(advice.suggestions) { suggestionCard($0) }
                    }
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        TextField("Anything to add? Craving something sweet, eating out…", text: $note, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...3)
                        Button { Task { await ask() } } label: {
                            Label(running ? "Asking…" : "Ask again", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(NoopButtonStyle(.secondary))
                        .disabled(running)
                    }
                    .padding(.top, NoopMetrics.space2)
                    Text("Today's numbers, targets and recipe list go to \(coach.provider.displayName) with your Coach key.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(NoopMetrics.screenPadding)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("What to eat")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .frame(minWidth: 380, minHeight: 460)
        .task { await ask() }
    }

    private func suggestionCard(_ s: NutritionAdvisor.Suggestion) -> some View {
        HStack(alignment: .top, spacing: NoopMetrics.space2) {
            VStack(alignment: .leading, spacing: 3) {
                Text(NutritionDayEditor.portionPrefix(s.portion) + s.name)
                    .font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(Int(s.kcal.rounded())) kcal · \(Int(s.proteinG.rounded())) g P"
                     + (s.recipeId == nil ? String(localized: " · estimate, not in your recipes") : ""))
                    .font(StrandFont.caption).monospacedDigit().foregroundStyle(StrandPalette.textSecondary)
                if !s.why.isEmpty {
                    Text(s.why).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: NoopMetrics.space2)
            if let recipeId = s.recipeId {
                if added.contains(s.id) {
                    Label("Added", systemImage: "checkmark").font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.statusPositive)
                } else {
                    Button("Add") { Task { await add(s, recipeId: recipeId) } }
                        .buttonStyle(NoopButtonStyle(.secondary))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoopPanelSurface(cornerRadius: 14))
    }

    private func ask() async {
        guard !running else { return }
        running = true
        defer { running = false }
        error = nil
        let now = Date()
        let day = await repo.nutritionDay(Repository.localDayKey(now))
        let recipes = await repo.nutritionRecipeList()
        let items = day.state == .untracked ? [] : day.items
        let eq = await NutritionTodayCard.load(repo)?.balance.equation
        var targets: [NutritionMacro: Int] = [:]
        for m in NutritionMacro.allCases { targets[m] = m.target }
        let context = NutritionAdvisor.Context(
            now: now, kcalLeft: -(eq?.total ?? 0), inKcal: eq?.inKcal ?? 0, outKcal: eq?.outKcal ?? 0,
            totals: NutritionMacro.totals(items, recipes: recipes), targets: targets, eaten: items,
            recipes: recipes, note: note)
        do {
            advice = try await NutritionAdvisor.ask(coach: coach, context)
            added = []
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func add(_ s: NutritionAdvisor.Suggestion, recipeId: String) async {
        let now = Date()
        let cal = Calendar.current
        let minute = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        await repo.editNutritionDay(Repository.localDayKey(now)) { rows in
            rows.append(NutritionItem(label: String(localized: "Added"), minuteOfDay: minute, recipeId: recipeId,
                                      portion: s.portion))
            rows.sort { ($0.minuteOfDay ?? 0) < ($1.minuteOfDay ?? 0) }
        }
        added.insert(s.id)
    }
}
