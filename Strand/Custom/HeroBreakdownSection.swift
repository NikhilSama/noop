import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// nikhil/custom — "what made up this score" for the three Today hero gauges, shown at the top of the
// metric detail page (above the existing trend chart). Charge → its engine drivers, Rest → the four
// weighted Rest sub-scores, Effort → the day's workouts with an approximate share of the day's load.
// Every input gets a RangeStrip against the selected window, anchored on the day being viewed.

struct HeroBreakdownSection: View {
    let metricKey: String
    let range: ExploreRange

    @EnvironmentObject private var repo: Repository
    @State private var day: String

    init(metricKey: String, initialDay: String, range: ExploreRange) {
        self.metricKey = metricKey
        self.range = range
        _day = State(initialValue: initialDay)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            dayStepper
            switch metricKey {
            case HeroRingMetric.charge: ChargeComposition(day: day, range: range)
            case HeroRingMetric.effort: EffortComposition(day: day, range: range)
            case HeroRingMetric.rest:   RestComposition(day: day, range: range)
            default: EmptyView()
            }
        }
    }

    // MARK: Day stepper

    private var todayKey: String { repo.today?.day ?? Repository.localDayKey(Date()) }
    private var firstKey: String? { repo.days.map(\.day).min() }

    private var dayStepper: some View {
        HStack(spacing: 12) {
            stepButton("chevron.left", enabled: firstKey.map { day > $0 } ?? false) { shift(-1) }
            Spacer(minLength: 0)
            VStack(spacing: 1) {
                Text(BreakdownDay.title(day, todayKey: todayKey))
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("vs your last \(range.name)")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 0)
            stepButton("chevron.right", enabled: day < todayKey) { shift(1) }
        }
        .padding(.horizontal, 6)
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(NoopPanelSurface(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? StrandPalette.textPrimary : StrandPalette.textTertiary.opacity(0.4))
        .disabled(!enabled)
    }

    private func shift(_ delta: Int) {
        guard let next = BreakdownDay.shift(day, by: delta) else { return }
        day = min(next, todayKey)
    }
}

// MARK: - Shared helpers

enum BreakdownDay {
    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ key: String) -> Date? { parser.date(from: key) }

    static func shift(_ key: String, by days: Int) -> String? {
        guard let d = date(key), let n = Calendar.current.date(byAdding: .day, value: days, to: d) else { return nil }
        return parser.string(from: n)
    }

    static func title(_ key: String, todayKey: String) -> String {
        if key == todayKey { return String(localized: "Today") }
        if shift(todayKey, by: -1) == key { return String(localized: "Yesterday") }
        guard let d = date(key) else { return key }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// The window the strips compare against: the `range` days ending on (and including) `day`.
    static func window(_ days: [DailyMetric], endingOn day: String, range: ExploreRange) -> [DailyMetric] {
        let upTo = days.filter { $0.day <= day }
        guard let n = range.days, let start = shift(day, by: -(n - 1)) else { return upTo }
        return upTo.filter { $0.day >= start }
    }

    /// Unix-second bounds of a local calendar day.
    static func bounds(_ key: String) -> (from: Int, to: Int)? {
        guard let d = date(key) else { return nil }
        let start = Calendar.current.startOfDay(for: d)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (Int(start.timeIntervalSince1970), Int(end.timeIntervalSince1970))
    }
}

/// The Rest score the rest of the app shows for a wake-day: the imported WHOOP figure when present,
/// else NOOP's resolved Rest composite (same precedence as SleepView.performanceScore).
@MainActor
func breakdownRestScore(_ repo: Repository, _ row: DailyMetric) -> Double? {
    repo.importedSleep[row.day]?.performancePct ?? AnalyticsEngine.Rest.composite(daily: row)
}

/// One labelled input: a header line (label, points chip, value) and its RangeStrip.
private struct BreakdownInputRow: View {
    let label: LocalizedStringKey
    var chip: String? = nil
    var chipColor: Color = StrandPalette.textTertiary
    let valueText: String
    var detailText: String? = nil
    let stats: RangeStats?
    let current: Double?
    let goodness: RangeGoodness
    let format: (Double) -> String
    var showLegend = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let chip {
                    Text(chip)
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(chipColor)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(chipColor.opacity(0.14), in: Capsule(style: .continuous))
                }
                Spacer(minLength: 8)
                Text(valueText)
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            if let detailText {
                Text(detailText)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let stats {
                RangeStrip(stats: stats, current: current, goodness: goodness, format: format,
                           showLegend: showLegend)
            }
        }
    }
}

private struct BreakdownHeader: View {
    let title: LocalizedStringKey
    let score: Double?
    let tint: Color
    var trailing: AnyView? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).strandOverline()
            if let score {
                Text("\(Int(score.rounded()))")
                    .font(StrandFont.number(20))
                    .foregroundStyle(tint)
            }
            Spacer()
            if let trailing { trailing }
        }
    }
}

private struct BreakdownNote: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func fmt0(_ v: Double) -> String { String(format: "%.0f", v) }

private func hoursMinutes(_ minutes: Double) -> String {
    let m = Int(minutes.rounded())
    return m >= 60 ? "\(m / 60)h \(String(format: "%02d", m % 60))m" : "\(m)m"
}

// MARK: - Charge

private struct ChargeComposition: View {
    let day: String
    let range: ExploreRange
    @EnvironmentObject private var repo: Repository

    private var row: DailyMetric? { repo.days.last(where: { $0.day == day }) }
    private var window: [DailyMetric] { BreakdownDay.window(repo.days, endingOn: day, range: range) }

    var body: some View {
        NoopCard(padding: 18, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                let breakdown = row.flatMap { r in
                    repo.chargeBaselines.flatMap {
                        ChargeBreakdownWiring.breakdown(baselines: $0, row: r,
                                                        sleepPerfPercent: breakdownRestScore(repo, r))
                    }
                }
                BreakdownHeader(title: "Charge · what shaped it", score: row?.recovery,
                                tint: StrandPalette.chargeColor,
                                trailing: breakdown.map { AnyView(ConfidenceTierChip(confidence: $0.confidence)) })
                if let stats = RangeStats(window.compactMap(\.recovery)) {
                    RangeStrip(stats: stats, current: row?.recovery, goodness: .higher, format: fmt0,
                               showLegend: true)
                }
                Divider().overlay(StrandPalette.hairline)
                if let breakdown, !breakdown.drivers.isEmpty {
                    ForEach(Array(breakdown.drivers.enumerated()), id: \.offset) { index, driver in
                        driverRow(driver)
                        if index < breakdown.drivers.count - 1 {
                            Divider().overlay(StrandPalette.hairline.opacity(0.5))
                        }
                    }
                    BreakdownNote(text: "Points show how much each input moved this day's Charge versus leaving it out. Values are compared with your current learned baselines.")
                } else {
                    BreakdownNote(text: "No breakdown for this day: Charge needs a scored night with HRV and resting heart rate, and enough nights for a baseline.")
                }
            }
        }
    }

    @ViewBuilder
    private func driverRow(_ d: ChargeDriver) -> some View {
        let spec = Self.series(for: d.label, repo: repo)
        let values = window.compactMap(spec.value)
        BreakdownInputRow(
            label: LocalizedStringKey(d.label),
            chip: ChargeBreakdownFormat.chipLabel(deltaPoints: d.deltaPoints),
            chipColor: ChargeBreakdownFormat.chipColor(deltaPoints: d.deltaPoints),
            valueText: d.valueText,
            detailText: [d.baselineText, d.verdict].filter { !$0.isEmpty }.joined(separator: " · "),
            stats: RangeStats(values),
            current: row.flatMap(spec.value),
            goodness: spec.goodness,
            format: spec.format)
    }

    private struct SeriesSpec {
        let value: (DailyMetric) -> Double?
        let goodness: RangeGoodness
        let format: (Double) -> String
    }

    /// Maps an engine driver label (RecoveryScorer.chargeDrivers) to its daily series.
    @MainActor
    private static func series(for label: String, repo: Repository) -> SeriesSpec {
        switch label {
        case "Heart rate variability":
            return SeriesSpec(value: { $0.avgHrv }, goodness: .higher, format: { String(format: "%.0f ms", $0) })
        case "Resting heart rate":
            return SeriesSpec(value: { $0.restingHr.map(Double.init) }, goodness: .lower,
                              format: { String(format: "%.0f bpm", $0) })
        case "Sleep quality":
            return SeriesSpec(value: { breakdownRestScore(repo, $0) }, goodness: .higher, format: fmt0)
        case "Respiratory rate":
            return SeriesSpec(value: { $0.respRateBpm }, goodness: .lower, format: { String(format: "%.1f", $0) })
        case "Skin temperature":
            return SeriesSpec(value: { $0.skinTempDevC }, goodness: .nearZero,
                              format: { String(format: "%+.1f°", $0) })
        default:
            return SeriesSpec(value: { _ in nil }, goodness: .neutral, format: fmt0)
        }
    }
}

// MARK: - Rest

/// The four Rest sub-scores, mirroring AnalyticsEngine.Rest.composite(daily:) exactly (default need,
/// neutral consistency) so the points add up to the composite the app displays.
struct RestParts {
    let durationScore, efficiencyScore, restorativeScore, consistencyScore: Double
    let asleepMin, needHours, efficiency, restorativeShare, deepShare: Double

    init?(_ d: DailyMetric) {
        typealias R = AnalyticsEngine.Rest
        guard let tstMin = d.totalSleepMin, tstMin > 0, let eff = d.efficiency else { return nil }
        func clamp01(_ x: Double) -> Double { max(0, min(1, x)) }
        let tst = tstMin * 60, deep = (d.deepMin ?? 0) * 60, rem = (d.remMin ?? 0) * 60
        asleepMin = tstMin
        needHours = R.defaultNeedHours
        efficiency = eff
        restorativeShare = (deep + rem) / tst
        deepShare = deep / tst
        durationScore = clamp01(tst / (needHours * 3600))
        efficiencyScore = clamp01(eff)
        let deepFactor = R.deepFloorFactor + (1 - R.deepFloorFactor) * clamp01(deepShare / R.deepShareTarget)
        restorativeScore = clamp01(restorativeShare / R.restorativeTarget) * deepFactor
        consistencyScore = R.neutralConsistency
    }

    typealias R = AnalyticsEngine.Rest
    var durationPts: Double { R.wDuration * durationScore * 100 }
    var efficiencyPts: Double { R.wEfficiency * efficiencyScore * 100 }
    var restorativePts: Double { R.wRestorative * restorativeScore * 100 }
    var consistencyPts: Double { R.wConsistency * consistencyScore * 100 }
    var total: Double { durationPts + efficiencyPts + restorativePts + consistencyPts }
}

private struct RestComposition: View {
    let day: String
    let range: ExploreRange
    @EnvironmentObject private var repo: Repository

    private var row: DailyMetric? { repo.days.last(where: { $0.day == day }) }
    private var window: [DailyMetric] { BreakdownDay.window(repo.days, endingOn: day, range: range) }

    var body: some View {
        NoopCard(padding: 18, tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                let shown = row.flatMap { breakdownRestScore(repo, $0) }
                BreakdownHeader(title: "Rest · what shaped it", score: shown, tint: StrandPalette.restColor)
                if let stats = RangeStats(window.compactMap { breakdownRestScore(repo, $0) }) {
                    RangeStrip(stats: stats, current: shown, goodness: .higher, format: fmt0, showLegend: true)
                }
                Divider().overlay(StrandPalette.hairline)
                if let row, let parts = RestParts(row) {
                    let windowParts = window.compactMap(RestParts.init)
                    BreakdownInputRow(
                        label: "Duration", chip: pts(parts.durationPts, of: R.wDuration),
                        chipColor: StrandPalette.restColor,
                        valueText: hoursMinutes(parts.asleepMin),
                        detailText: String(format: String(localized: "%@ asleep of %@ needed (%.0f%%)"),
                                           hoursMinutes(parts.asleepMin), hoursMinutes(parts.needHours * 60),
                                           parts.durationScore * 100),
                        stats: RangeStats(windowParts.map(\.asleepMin)), current: parts.asleepMin,
                        goodness: .higher, format: hoursMinutes)
                    BreakdownInputRow(
                        label: "Efficiency", chip: pts(parts.efficiencyPts, of: R.wEfficiency),
                        chipColor: StrandPalette.restColor,
                        valueText: String(format: "%.0f%%", parts.efficiency * 100),
                        detailText: String(localized: "Time asleep vs time in bed"),
                        stats: RangeStats(windowParts.map { $0.efficiency * 100 }), current: parts.efficiency * 100,
                        goodness: .higher, format: { String(format: "%.0f%%", $0) })
                    BreakdownInputRow(
                        label: "Restorative", chip: pts(parts.restorativePts, of: R.wRestorative),
                        chipColor: StrandPalette.restColor,
                        valueText: String(format: "%.0f%%", parts.restorativeShare * 100),
                        detailText: String(format: String(localized: "Deep + REM share of sleep (full marks at %.0f%%); deep %.0f%%"),
                                           R.restorativeTarget * 100, parts.deepShare * 100),
                        stats: RangeStats(windowParts.map { $0.restorativeShare * 100 }),
                        current: parts.restorativeShare * 100,
                        goodness: .higher, format: { String(format: "%.0f%%", $0) })
                    BreakdownInputRow(
                        label: "Consistency", chip: pts(parts.consistencyPts, of: R.wConsistency),
                        chipColor: StrandPalette.restColor,
                        valueText: String(localized: "neutral"),
                        detailText: String(localized: "This score gives a fixed neutral credit for bed/wake regularity; see the Sleep tab for your actual consistency."),
                        stats: nil, current: nil, goodness: .neutral, format: fmt0)
                    StageBar(row: row)
                    if let shown, abs(shown - parts.total) >= 1 {
                        BreakdownNote(text: "This day's Rest score came from an imported source, so the parts above are XYLO's own estimate and may not add up to it exactly.")
                    }
                    NavigationLink(value: TabRoute.sleep) {
                        HStack {
                            Text("Open in Sleep tab").font(StrandFont.subhead)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(StrandPalette.accent)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    BreakdownNote(text: "No sleep recorded for this day.")
                }
            }
        }
    }

    private typealias R = AnalyticsEngine.Rest

    private func pts(_ p: Double, of weight: Double) -> String {
        "\(Int(p.rounded())) / \(Int((weight * 100).rounded())) pts"
    }
}

private struct StageBar: View {
    let row: DailyMetric

    private var segments: [(LocalizedStringKey, Double, Color)] {
        let tst = row.totalSleepMin ?? 0
        let inBed = row.efficiency.map { tst / max($0, 0.01) } ?? tst
        let deep = row.deepMin ?? 0, rem = row.remMin ?? 0
        let light = row.lightMin ?? max(0, tst - deep - rem)
        return [("Awake", max(0, inBed - tst), StrandPalette.sleepAwake),
                ("Light", light, StrandPalette.sleepLight),
                ("Deep", deep, StrandPalette.sleepDeep),
                ("REM", rem, StrandPalette.sleepREM)]
    }

    var body: some View {
        let segs = segments
        let total = max(1, segs.reduce(0) { $0 + $1.1 })
        VStack(alignment: .leading, spacing: 6) {
            Text("Stages").strandOverline()
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(segs.enumerated()), id: \.offset) { _, s in
                        if s.1 > 0 {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(s.2)
                                .frame(width: max(2, (geo.size.width - 6) * s.1 / total))
                        }
                    }
                }
            }
            .frame(height: 12)
            HStack(spacing: 12) {
                ForEach(Array(segs.enumerated()), id: \.offset) { _, s in
                    HStack(spacing: 4) {
                        Circle().fill(s.2).frame(width: 7, height: 7)
                        Text(s.0).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        Text(hoursMinutes(s.1)).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - Effort

/// Splits a day's Effort across its workouts. Effort is log-mapped (100·ln(T+1)/ln D), so scores don't
/// add; inverting each score to its load T = D^(e/100) − 1 gives an additive quantity to share out.
/// Approximate by construction: a workout's own score and the day's score come from separate passes.
struct EffortSplit {
    struct Item { let row: WorkoutRow; let share: Double }
    let items: [Item]
    let everydayShare: Double?

    static func load(_ effort: Double) -> Double {
        pow(StrainScorer.strainDenominator, max(0, effort) / 100) - 1
    }

    init(dayEffort: Double?, workouts: [WorkoutRow]) {
        let loads = workouts.map { Self.load($0.strain ?? 0) }
        let workoutTotal = loads.reduce(0, +)
        let dayLoad = dayEffort.map(Self.load) ?? 0
        let denominator = max(workoutTotal, dayLoad)
        guard denominator > 0 else {
            items = workouts.map { Item(row: $0, share: 0) }
            everydayShare = dayEffort == nil ? nil : 1
            return
        }
        items = zip(workouts, loads).map { Item(row: $0, share: $1 / denominator) }
        everydayShare = dayLoad > workoutTotal ? (dayLoad - workoutTotal) / denominator : nil
    }
}

private struct EffortComposition: View {
    let day: String
    let range: ExploreRange
    @EnvironmentObject private var repo: Repository
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    @State private var workouts: [WorkoutRow] = []
    @State private var detail: WorkoutRow?

    private var row: DailyMetric? { repo.days.last(where: { $0.day == day }) }
    private var window: [DailyMetric] { BreakdownDay.window(repo.days, endingOn: day, range: range) }
    private var whoopScale: Bool { UnitPrefs.resolveEffortScale(effortScaleRaw) == .whoop }

    private func effortText(_ v: Double) -> String {
        whoopScale ? String(format: "%.1f", v * 21 / 100) : String(format: "%.0f", v)
    }

    var body: some View {
        NoopCard(padding: 18, tint: StrandPalette.effortColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                BreakdownHeader(title: "Effort · how the day's load splits", score: nil, tint: StrandPalette.effortColor,
                                trailing: row?.strain.map {
                                    AnyView(Text(effortText($0)).font(StrandFont.number(20))
                                        .foregroundStyle(StrandPalette.effortColor))
                                })
                if let stats = RangeStats(window.compactMap(\.strain)) {
                    RangeStrip(stats: stats, current: row?.strain, goodness: .neutral, format: effortText,
                               showLegend: true)
                }
                Divider().overlay(StrandPalette.hairline)
                table
                BreakdownNote(text: "≈ Share of day converts each Effort score back to training load, which adds up across the day. Effort itself is logarithmic, so the scores don't sum. Everyday activity is whatever load the logged workouts don't explain.")
            }
        }
        .task(id: day) {
            guard let b = BreakdownDay.bounds(day) else { workouts = []; return }
            workouts = await repo.workoutRows()
                .filter { $0.startTs >= b.from && $0.startTs < b.to }
                .sorted { $0.startTs < $1.startTs }
        }
        .sheet(item: Binding(get: { detail.map(IdentifiedWorkout.init) },
                             set: { detail = $0?.row })) { target in
            NavigationStack {
                WorkoutDetailView(row: target.row)
                    .environmentObject(repo)
            }
            #if os(iOS)
            .noopSheetPresentation(largeFirst: true)
            #else
            .frame(width: 620, height: 720)
            #endif
        }
    }

    @ViewBuilder
    private var table: some View {
        let split = EffortSplit(dayEffort: row?.strain, workouts: workouts)
        if workouts.isEmpty && split.everydayShare == nil {
            BreakdownNote(text: "No Effort or workouts recorded for this day.")
        } else {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    header("Workout")
                    header("Dur").gridColumnAlignment(.trailing)
                    header("HR").gridColumnAlignment(.trailing)
                    header("kcal").gridColumnAlignment(.trailing)
                    header("Effort").gridColumnAlignment(.trailing)
                    header("≈Share").gridColumnAlignment(.trailing)
                }
                ForEach(Array(split.items.enumerated()), id: \.offset) { _, item in
                    workoutRow(item)
                }
                if let everyday = split.everydayShare {
                    GridRow {
                        cell(Text("Everyday activity").foregroundColor(StrandPalette.textSecondary))
                        dash; dash; dash; dash
                        cell(Text(percent(everyday)))
                    }
                    shareBar(everyday, tint: StrandPalette.textTertiary)
                }
            }
        }
    }

    private func workoutRow(_ item: EffortSplit.Item) -> some View {
        let w = item.row
        return Group {
            GridRow {
                VStack(alignment: .leading, spacing: 1) {
                    Text(WorkoutSource.displaySport(w.sport))
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Text(Date(timeIntervalSince1970: TimeInterval(w.startTs)).formatted(date: .omitted, time: .shortened))
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                cell(Text(w.durationS.map { hoursMinutes($0 / 60) } ?? "—"))
                cell(Text(w.avgHr.map { "\($0)" } ?? "—"))
                cell(Text(w.energyKcal.map { String(format: "%.0f", $0) } ?? "—"))
                cell(Text(w.strain.map(effortText) ?? "—"))
                cell(Text(percent(item.share)).foregroundColor(StrandPalette.effortColor))
            }
            .contentShape(Rectangle())
            .onTapGesture { detail = w }
            shareBar(item.share, tint: StrandPalette.effortColor)
        }
    }

    private func shareBar(_ share: Double, tint: Color) -> some View {
        GridRow {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.hairline)
                    Capsule().fill(tint).frame(width: geo.size.width * max(0, min(1, share)))
                }
            }
            .frame(height: 4)
            .gridCellColumns(6)
        }
    }

    private func header(_ t: LocalizedStringKey) -> some View {
        Text(t).font(StrandFont.overline).foregroundStyle(StrandPalette.textTertiary)
    }

    private func cell(_ t: Text) -> some View {
        t.font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
    }

    private var dash: some View { cell(Text("—")) }

    private func percent(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
}

private struct IdentifiedWorkout: Identifiable {
    let row: WorkoutRow
    var id: Int { row.startTs }
}
