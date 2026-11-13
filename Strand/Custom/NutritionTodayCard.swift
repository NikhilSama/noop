import SwiftUI
import StrandDesign
import WhoopStore

// nikhil/custom — the Today nutrition card: two bars on one scale.
//   IN   standard day │ extras │ deficit
//   OUT  resting (RMR) │ digestion (TEF) │ active so far
// The deficit segment is the real gap (out − in); a tick marks the target. When in > out the gap shows as a
// red surplus on the OUT bar instead. The headline is in + planned deficit − out, so 0 is on plan, coloured
// by `NutritionBand`; under the bars the same sum as an equation. One line names both levers, one the
// Mon–Sun ledger.
struct NutritionTodayCard: View {
    /// On Today the card opens the Nutrition screen; on that screen it doesn't link to itself.
    var linksToScreen = true
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
        // The load runs on a view that exists as soon as Nutrition is on: on an empty Group the task would
        // never run, and the card would wait forever for the load that makes it appear. Off, nothing renders.
        if enabled {
            ZStack {
                Color.clear.frame(height: 0)
                if let snapshot {
                    if linksToScreen {
                        NavigationLink { NutritionView() } label: {
                            NoopCard(tint: StrandPalette.metricAmber) { content(snapshot) }
                        }
                        .buttonStyle(.plain)
                    } else {
                        NoopCard(tint: StrandPalette.metricAmber) { content(snapshot) }
                    }
                }
            }
            .task(id: "\(repo.refreshSeq)-\(changes.seq)") { snapshot = await Self.load(repo) }
        }
    }

    // MARK: Drawing

    private func content(_ s: Snapshot) -> some View {
        let b = s.balance
        let eq = b.equation
        // One scale for both bars: whichever side is longer, plus the deficit target when it reaches further.
        let scale = max(b.inKcal + max(0, -b.balance), b.outKcal + max(0, b.balance), b.inKcal - b.targetBalance, 1)
        return VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack(spacing: NoopMetrics.space2) {
                Image(systemName: "fork.knife").foregroundStyle(StrandPalette.metricAmber)
                Text("Nutrition").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text(Self.signed(Double(eq.total))).font(StrandFont.headline).monospacedDigit()
                    .foregroundStyle(NutritionBand.of(offPlan: Double(eq.total), target: b.targetBalance).color)
            }
            if !s.hasStandard {
                Text("Import your vault file in Settings → Features to set up your standard day.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            // IN is green / yellow / grey and OUT blues and cyan, so no colour means two things.
            bar(label: "In", scale: scale, segments: [
                (b.standardKcal, StrandPalette.statusPositive),
                (b.extraKcal, StrandPalette.metricAmber),
                (max(0, -b.balance), StrandPalette.textTertiary.opacity(0.55)),
            ], ticks: [(b.inKcal - b.targetBalance, StrandPalette.textPrimary)]
               + (b.fullStandardKcal > b.standardKcal + 1 ? [(b.fullStandardKcal, StrandPalette.textTertiary)] : []))
            bar(label: "Out", scale: scale, segments: [
                (b.rmrKcal, StrandPalette.metricPurple),
                (b.tefKcal, StrandPalette.xyloBlueBright),
                (b.activeKcal, StrandPalette.metricCyan),
                (max(0, b.balance), StrandPalette.statusCritical),
            ], ticks: [])
            Text(Self.equationText(eq))
                .font(StrandFont.caption).monospacedDigit().foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
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

    /// "+15 = 1428 (1428 + 0) + 300 − 1713 (1217 + 143 + 353)": total = in (standard + extra) + planned
    /// deficit − out (resting + digestion + active).
    static func equationText(_ e: NutritionBalance.Equation) -> String {
        let deficit = e.deficit >= 0 ? "+ \(e.deficit)" : "− \(-e.deficit)"
        return "\(signed(Double(e.total))) = \(e.inKcal) (\(e.standard) + \(e.extra)) \(deficit) − \(e.outKcal) (\(e.rmr) + \(e.tef) + \(e.active))"
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
        let now = Date()
        let todayKey = Repository.localDayKey(now)
        let mondayKey = Repository.localDayKey(NutritionHistory.monday(of: now))
        guard let loaded = await NutritionHistory.load(repo, from: mondayKey, to: todayKey, now: now) else { return nil }
        let week = loaded.days.reduce(0) { $0 + $1.balance.balance }
        let today = loaded.days.first { $0.isToday }
        let balance: NutritionBalance
        if let today {
            balance = today.balance
        } else {
            // Untracked or before the first standard: nothing in, the burn so far out.
            guard let store = await repo.nutritionStore() else { return nil }
            let strap = await repo.dailyMetrics(fromDay: todayKey, toDay: todayKey).first?.activeKcalEst
            let apple = (try? await store.appleDaily(deviceId: "apple-health", from: todayKey, to: todayKey))?.first?.activeKcal
            let elapsed = now.timeIntervalSince(Calendar.current.startOfDay(for: now)) / 86_400
            balance = NutritionBalance.make(
                day: NutritionDay(day: todayKey, state: .none, items: []), standardSlots: [], recipes: loaded.recipes,
                appleActiveKcal: apple, strapDayKcal: strap, dayFraction: elapsed)
        }
        let trim = today.flatMap { NutritionBalance.trimSuggestion(items: $0.items, recipes: loaded.recipes, need: balance.toGo) }
        return Snapshot(balance: balance, trim: trim.map { ($0.name, $0.saves) }, weekBalance: week,
                        weekTarget: Double(NutritionPlan.targetBalance) * 7, hasStandard: loaded.hasStandard)
    }
}
