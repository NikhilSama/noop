import SwiftUI
import StrandDesign
import WhoopStore

// nikhil/custom — the Today nutrition card: two bars on one scale.
//   IN   standard day │ extras │ deficit
//   OUT  resting (RMR) │ digestion (TEF) │ active so far
// The deficit segment is the real gap (out − in); a tick marks the target. When in > out the gap shows as a
// red surplus on the OUT bar instead. One line names both levers, one the Mon–Sun ledger.
struct NutritionTodayCard: View {
    @EnvironmentObject private var repo: Repository
    @AppStorage(NutritionPrefs.enabledKey) private var enabled = false
    @ObservedObject private var changes = NutritionChanges.shared
    @State private var snapshot: Snapshot?

    struct Snapshot: Equatable {
        var balance: NutritionBalance
        var trim: (name: String, saves: Double)?
        var weekBalance: Double
        var weekTarget: Double
        var hasStandard: Bool

        static func == (a: Snapshot, b: Snapshot) -> Bool {
            a.balance == b.balance && a.trim?.name == b.trim?.name && a.trim?.saves == b.trim?.saves
                && a.weekBalance == b.weekBalance && a.weekTarget == b.weekTarget && a.hasStandard == b.hasStandard
        }
    }

    var body: some View {
        Group {
            if enabled, let snapshot {
                NoopCard(tint: StrandPalette.metricAmber) { content(snapshot) }
            }
        }
        .task(id: "\(repo.refreshSeq)-\(changes.seq)-\(enabled)") {
            snapshot = enabled ? await Self.load(repo) : nil
        }
    }

    // MARK: Drawing

    private func content(_ s: Snapshot) -> some View {
        let b = s.balance
        // One scale for both bars: whichever side is longer, plus the deficit target when it reaches further.
        let scale = max(b.inKcal + max(0, -b.balance), b.outKcal + max(0, b.balance), b.inKcal - b.targetBalance, 1)
        return VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack(spacing: NoopMetrics.space2) {
                Image(systemName: "fork.knife").foregroundStyle(StrandPalette.metricAmber)
                Text("Nutrition").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text(Self.signed(b.balance)).font(StrandFont.headline).monospacedDigit()
                    .foregroundStyle(b.hit ? StrandPalette.statusPositive : StrandPalette.statusWarning)
            }
            if !s.hasStandard {
                Text("Import your vault file in Settings → Features to set up your standard day.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            bar(label: "In", scale: scale, segments: [
                (b.standardKcal, StrandPalette.accent),
                (b.extraKcal, StrandPalette.metricAmber),
                (max(0, -b.balance), b.hit ? StrandPalette.statusPositive : StrandPalette.statusWarning),
            ], ticks: [(b.inKcal - b.targetBalance, StrandPalette.textPrimary)]
               + (b.fullStandardKcal > b.standardKcal + 1 ? [(b.fullStandardKcal, StrandPalette.textTertiary)] : []))
            bar(label: "Out", scale: scale, segments: [
                (b.rmrKcal, StrandPalette.metricPurple),
                (b.tefKcal, StrandPalette.metricCyan),
                (b.activeKcal, StrandPalette.statusPositive),
                (max(0, b.balance), StrandPalette.statusCritical),
            ], ticks: [])
            legend(b)
            Text(lever(s)).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Week: \(Self.signed(s.weekBalance)) of \(Self.signed(s.weekTarget))")
                .font(StrandFont.caption).monospacedDigit().foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func bar(label: LocalizedStringKey, scale: Double, segments: [(Double, Color)],
                     ticks: [(Double, Color)]) -> some View {
        HStack(spacing: NoopMetrics.space2) {
            Text(label).font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 30, alignment: .leading)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.textTertiary.opacity(0.12))
                    HStack(spacing: 1) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                            if seg.0 > 0.5 {
                                Rectangle().fill(seg.1).frame(width: max(2, w * seg.0 / scale))
                            }
                        }
                    }
                    .clipShape(Capsule())
                    ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                        Rectangle().fill(tick.1).frame(width: 2, height: 18)
                            .offset(x: min(w - 2, max(0, w * tick.0 / scale - 1)))
                    }
                }
            }
            .frame(height: 14)
        }
    }

    private func legend(_ b: NutritionBalance) -> some View {
        Text("In \(Int(b.inKcal.rounded())) · Out \(Int(b.outKcal.rounded())) (resting \(Int(b.rmrKcal)), digestion \(Int(b.tefKcal.rounded())), active \(Int(b.activeKcal.rounded())))")
            .font(StrandFont.caption).monospacedDigit().foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func lever(_ s: Snapshot) -> String {
        let b = s.balance
        if b.hit { return String(localized: "Target hit, \(Int(b.spare.rounded())) to spare") }
        let toGo = Int(b.toGo.rounded())
        if let trim = s.trim {
            return String(localized: "\(toGo) to go: burn it, or drop ½ \(trim.name) (−\(Int(trim.saves.rounded())))")
        }
        return String(localized: "\(toGo) to go: burn it, or eat less")
    }

    static func signed(_ v: Double) -> String {
        let n = Int(v.rounded())
        return n > 0 ? "+\(n)" : (n < 0 ? "−\(-n)" : "0")
    }

    // MARK: Loading

    static func load(_ repo: Repository) async -> Snapshot? {
        guard let store = await repo.nutritionStore() else { return nil }
        let now = Date()
        let todayKey = Repository.localDayKey(now)
        let cal = Calendar.current
        // Monday-start week regardless of locale (the vault's ledger week).
        var monday = cal.startOfDay(for: now)
        while cal.component(.weekday, from: monday) != 2 { monday = cal.date(byAdding: .day, value: -1, to: monday) ?? monday }
        let mondayKey = Repository.localDayKey(monday)

        let recipes = (try? await store.nutritionRecipes()) ?? [:]
        let versions = (try? await store.nutritionStandardVersions()) ?? []
        let days = await repo.nutritionDays(from: mondayKey, to: todayKey)
        let metrics = await repo.dailyMetrics(fromDay: mondayKey, toDay: todayKey)
        let apple = (try? await store.appleDaily(deviceId: "apple-health", from: mondayKey, to: todayKey)) ?? []
        let strapByDay = Dictionary(metrics.map { ($0.day, $0.activeKcalEst) }, uniquingKeysWith: { a, _ in a })
        let appleByDay = Dictionary(apple.map { ($0.day, $0.activeKcal) }, uniquingKeysWith: { a, _ in a })
        let elapsed = now.timeIntervalSince(cal.startOfDay(for: now)) / 86_400

        var week = 0.0
        var today: NutritionBalance?
        var todayDay: NutritionDay?
        for day in days where day.state == .standard || day.state == .edited {
            let slots = NutritionResolve.standardSlots(on: day.day, versions: versions) ?? []
            let b = NutritionBalance.make(day: day, standardSlots: slots, recipes: recipes,
                                          appleActiveKcal: appleByDay[day.day] ?? nil,
                                          strapDayKcal: strapByDay[day.day] ?? nil,
                                          dayFraction: day.day == todayKey ? elapsed : 1)
            week += b.balance
            if day.day == todayKey { today = b; todayDay = day }
        }
        let hasStandard = !versions.isEmpty
        let balance = today ?? NutritionBalance.make(
            day: NutritionDay(day: todayKey, state: .none, items: []), standardSlots: [], recipes: recipes,
            appleActiveKcal: appleByDay[todayKey] ?? nil, strapDayKcal: strapByDay[todayKey] ?? nil, dayFraction: elapsed)
        let trim = todayDay.flatMap { NutritionBalance.trimSuggestion(items: $0.items, recipes: recipes, need: balance.toGo) }
        return Snapshot(balance: balance, trim: trim.map { ($0.name, $0.saves) }, weekBalance: week,
                        weekTarget: Double(NutritionPlan.targetBalance) * 7, hasStandard: hasStandard)
    }
}
