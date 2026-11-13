import SwiftUI
import Charts
import StrandDesign
import WhoopStore

// nikhil/custom — the Nutrition screen's Trends tab, over W / M / 3M / 6M / 1Y:
//   • four numbers for the span (average balance, days on target, average intake against burn, the fat
//     the balance adds up to at 7,700 kcal/kg);
//   • intake vs burn: a bar per day for what went in, the line for what went out;
//   • the daily balance (in − out) as bars coloured by `NutritionBand` against the target, the target as a
//     dashed line, and each Mon–Sun week's average as a flat line across that week;
//   • macro averages against their targets, and the weekly ledger.
// Tap either chart for that day's numbers. Averages use complete days: today, still filling, is drawn
// faint and left out of them. Days marked not tracked are gaps.
struct NutritionTrendsView: View {
    @EnvironmentObject private var repo: Repository
    @ObservedObject private var changes = NutritionChanges.shared
    @State private var range: Span = .month
    @State private var days: [NutritionHistory.Day] = []
    @State private var loaded = false
    @State private var selected: String?

    enum Span: Int, CaseIterable, Identifiable {
        case week = 7, month = 30, quarter = 90, half = 180, year = 365
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .week: return String(localized: "W")
            case .month: return String(localized: "M")
            case .quarter: return String(localized: "3M")
            case .half: return String(localized: "6M")
            case .year: return String(localized: "1Y")
            }
        }
    }

    private var target: Double { Double(NutritionPlan.targetBalance) }
    private var complete: [NutritionHistory.Day] { days.filter { !$0.isToday } }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            SegmentedPillControl(Span.allCases, selection: $range, adaptsToAvailableWidth: true) { $0.label }
            if loaded && days.isEmpty {
                NoopCard {
                    Text("No tracked days in this span yet.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }
            } else if !days.isEmpty {
                summary
                if let s = selectedDay { dayDetail(s) }
                card("Intake vs burn", legend: [("In", StrandPalette.metricAmber), ("Out", StrandPalette.metricPurple)]) {
                    intakeChart
                }
                card("Daily balance", legend: [("Weekly average", StrandPalette.textPrimary),
                                               ("Target", StrandPalette.textTertiary)]) {
                    balanceChart
                }
                macros
                if range != .week { ledger }
            }
        }
        .task(id: "\(range.rawValue)-\(changes.seq)-\(repo.refreshSeq)") { await reload() }
    }

    private func reload() async {
        let now = Date()
        let from = Calendar.current.date(byAdding: .day, value: -(range.rawValue - 1), to: now) ?? now
        let loaded = await NutritionHistory.load(repo, from: Repository.localDayKey(from),
                                                 to: Repository.localDayKey(now), now: now)
        days = loaded?.days ?? []
        if let s = selected, !days.contains(where: { $0.day == s }) { selected = nil }
        self.loaded = true
    }

    // MARK: Summary

    private var summary: some View {
        let c = complete
        let n = Double(max(c.count, 1))
        let avgBalance = c.reduce(0) { $0 + $1.balance.balance } / n
        let avgIn = c.reduce(0) { $0 + $1.balance.inKcal } / n
        let avgOut = c.reduce(0) { $0 + $1.balance.outKcal } / n
        let onTarget = c.filter { Self.onTarget($0.balance) }.count
        let fatKg = c.reduce(0) { $0 + $1.balance.balance } / 7700
        let band = NutritionBand.of(offPlan: avgBalance - target, target: target)
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: NoopMetrics.space3),
                                   GridItem(.flexible(), spacing: NoopMetrics.space3)],
                         spacing: NoopMetrics.space3) {
            tile("Average balance", c.isEmpty ? "–" : NutritionTodayCard.signed(avgBalance),
                 String(localized: "kcal/day · target \(NutritionTodayCard.signed(target))"), c.isEmpty ? nil : band.color)
            tile("On target", c.isEmpty ? "–" : "\(onTarget)/\(c.count)",
                 String(localized: "days within 100 kcal of it, or under"), nil)
            tile("Intake", c.isEmpty ? "–" : "\(Int(avgIn.rounded()))",
                 String(localized: "kcal/day · burn \(Int(avgOut.rounded()))"), nil)
            tile("Fat", c.isEmpty ? "–" : String(format: "%@%.2f kg", fatKg > 0 ? "+" : "−", abs(fatKg)),
                 String(localized: "the balance at 7,700 kcal/kg"), nil)
        }
    }

    /// At the target, under it, or no more than 100 kcal over.
    static func onTarget(_ b: NutritionBalance) -> Bool { b.balance <= b.targetBalance + NutritionBand.onPlanKcal }

    private func tile(_ label: LocalizedStringKey, _ value: String, _ caption: String, _ accent: Color?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).strandOverline()
            Text(value).font(StrandFont.rounded(24, weight: .semibold)).monospacedDigit()
                .foregroundStyle(accent ?? StrandPalette.textPrimary)
            Text(caption).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoopPanelSurface(cornerRadius: 16))
    }

    // MARK: Charts

    private struct Point: Identifiable {
        var day: String
        var date: Date
        var b: NutritionBalance
        var isToday: Bool
        var id: String { day }
    }

    private var points: [Point] {
        days.compactMap { d in NutritionHistory.date(d.day).map { Point(day: d.day, date: $0, b: d.balance, isToday: d.isToday) } }
    }

    private var intakeChart: some View {
        let pts = points
        return Chart {
            ForEach(pts) { p in
                BarMark(x: .value("Day", p.date, unit: .day), y: .value("In", p.b.inKcal))
                    .foregroundStyle(StrandPalette.metricAmber.opacity(p.isToday ? 0.35 : 0.85))
                    .cornerRadius(2)
            }
            ForEach(pts) { p in
                LineMark(x: .value("Day", p.date, unit: .day), y: .value("Out", p.b.outKcal))
                    .foregroundStyle(StrandPalette.metricPurple)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
                if range.rawValue <= 30 {
                    PointMark(x: .value("Day", p.date, unit: .day), y: .value("Out", p.b.outKcal))
                        .foregroundStyle(StrandPalette.metricPurple)
                        .symbolSize(18)
                }
            }
            selectionRule
        }
        .chartXAxis { xAxis }
        .chartOverlay { proxy in tapLayer(proxy) }
        .frame(height: NoopMetrics.chartHeight)
    }

    private var balanceChart: some View {
        let pts = points
        let weeks = NutritionHistory.weeks(days)
        let lo = pts.first?.date ?? Date()
        let hi = Calendar.current.date(byAdding: .day, value: 1, to: pts.last?.date ?? Date()) ?? Date()
        return Chart {
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(StrandPalette.textTertiary.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1))
            ForEach(pts) { p in
                BarMark(x: .value("Day", p.date, unit: .day), y: .value("Balance", p.b.balance))
                    .foregroundStyle(NutritionBand.of(offPlan: p.b.balance - target, target: target).color
                        .opacity(p.isToday ? 0.35 : 0.8))
                    .cornerRadius(2)
            }
            RuleMark(y: .value("Target", target))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            ForEach(weeks) { w in
                RuleMark(xStart: .value("From", max(w.start, lo)),
                         xEnd: .value("To", min(Calendar.current.date(byAdding: .day, value: 7, to: w.start) ?? w.start, hi)),
                         y: .value("Weekly average", w.averageBalance))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .annotation(position: w.averageBalance > 0 ? .top : .bottom, alignment: .leading, spacing: 2) {
                        if range.rawValue <= 90 {
                            Text(NutritionTodayCard.signed(w.averageBalance))
                                .font(StrandFont.caption.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
            }
            selectionRule
        }
        .chartXAxis { xAxis }
        .chartOverlay { proxy in tapLayer(proxy) }
        .frame(height: NoopMetrics.chartHeight)
    }

    @ChartContentBuilder private var selectionRule: some ChartContent {
        if let s = selected, let d = NutritionHistory.date(s),
           let mid = Calendar.current.date(byAdding: .hour, value: 12, to: d) {
            RuleMark(x: .value("Selected", mid))
                .foregroundStyle(StrandPalette.textSecondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
    }

    private var xAxis: some AxisContent {
        AxisMarks(values: range == .week ? .stride(by: .day) : (range == .month ? .stride(by: .weekOfYear) : .stride(by: .month))) { _ in
            AxisGridLine().foregroundStyle(StrandPalette.textTertiary.opacity(0.15))
            if range == .week {
                AxisValueLabel(format: .dateTime.weekday(.abbreviated))
            } else if range == .month {
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            } else {
                AxisValueLabel(format: .dateTime.month(.abbreviated))
            }
        }
    }

    /// Tap a day for its numbers; tap it again to close them.
    private func tapLayer(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { value in
                    let plot = geo[proxy.plotAreaFrame]   // macOS 13 API (plotFrame is 14+)
                    guard let date: Date = proxy.value(atX: value.location.x - plot.origin.x) else { return }
                    let key = Repository.localDayKey(date)
                    guard days.contains(where: { $0.day == key }) else { return }
                    selected = selected == key ? nil : key
                })
        }
    }

    // MARK: A day

    private var selectedDay: NutritionHistory.Day? { selected.flatMap { s in days.first { $0.day == s } } }

    private func dayDetail(_ d: NutritionHistory.Day) -> some View {
        let eq = d.balance.equation
        let title = NutritionHistory.date(d.day)?.formatted(.dateTime.weekday(.wide).day().month(.wide)) ?? d.day
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack {
                    Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    if d.isToday {
                        Text("so far").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer()
                    Button { selected = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(StrandPalette.textTertiary)
                }
                HStack(spacing: NoopMetrics.space4) {
                    figure("In", "\(eq.inKcal)")
                    figure("Out", "\(eq.outKcal)")
                    figure("Balance", NutritionTodayCard.signed(d.balance.balance),
                           NutritionBand.of(offPlan: d.balance.balance - target, target: target).color)
                }
                Text(NutritionTodayCard.equationText(eq))
                    .font(StrandFont.caption).monospacedDigit().foregroundStyle(StrandPalette.textTertiary)
                Text(NutritionMacro.allCases.map { "\($0.title) \(Int($0.grams(d.macros).rounded())) g" }.joined(separator: " · "))
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func figure(_ label: LocalizedStringKey, _ value: String, _ color: Color = StrandPalette.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Text(value).font(StrandFont.headline).monospacedDigit().foregroundStyle(color)
        }
    }

    // MARK: Macros

    private var macros: some View {
        let c = complete
        let n = Double(max(c.count, 1))
        return card("Macros, average per day", legend: []) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                ForEach(NutritionMacro.allCases) { m in
                    let t = Double(m.target)
                    let avg = c.reduce(0) { $0 + m.grams($1.macros) } / n
                    let hit = c.filter { m.status(m.grams($0.macros), target: t) == .good }.count
                    let status = m.status(avg, target: t)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(m.title).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            Text("\(c.isEmpty ? "–" : String(format: avg < 10 ? "%.1f" : "%.0f", avg)) g · \(m.kindWord) \(m.target)")
                                .font(StrandFont.caption).monospacedDigit().foregroundStyle(StrandPalette.textSecondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(StrandPalette.textTertiary.opacity(0.12))
                                Capsule().fill(status.color).frame(width: geo.size.width * min(avg / max(t, 0.1), 1))
                            }
                        }
                        .frame(height: 6)
                        Text("Good on \(hit) of \(c.count) days")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    // MARK: Weeks

    private var ledger: some View {
        let weeks = NutritionHistory.weeks(days).reversed()
        return card("Weeks", legend: []) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Week of").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Per day").frame(width: 70, alignment: .trailing)
                    Text("Total").frame(width: 70, alignment: .trailing)
                    Text("Days").frame(width: 40, alignment: .trailing)
                }
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                .padding(.bottom, 6)
                ForEach(Array(weeks)) { w in
                    Divider()
                    HStack {
                        Text(w.start.formatted(.dateTime.day().month(.abbreviated)))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(NutritionTodayCard.signed(w.averageBalance))
                            .foregroundStyle(NutritionBand.of(offPlan: w.averageBalance - target, target: target).color)
                            .frame(width: 70, alignment: .trailing)
                        Text(NutritionTodayCard.signed(w.totalBalance)).frame(width: 70, alignment: .trailing)
                        Text("\(w.days)").frame(width: 40, alignment: .trailing)
                            .foregroundStyle(w.days < 7 ? StrandPalette.textTertiary : StrandPalette.textSecondary)
                    }
                    .font(StrandFont.subhead).monospacedDigit().foregroundStyle(StrandPalette.textPrimary)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: Pieces

    private func card<V: View>(_ title: LocalizedStringKey, legend: [(LocalizedStringKey, Color)],
                               @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).strandOverline()
                Spacer()
                ForEach(Array(legend.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 4) {
                        Circle().fill(item.1).frame(width: 7, height: 7)
                        Text(item.0).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoopPanelSurface(cornerRadius: 18))
    }
}
