import SwiftUI
import Charts
import StrandDesign
import WhoopStore

// nikhil/custom — hours asleep per night as stacked stages: deep at the bottom, then REM, then light, and
// whatever the night's total holds beyond the three (a night with no staging, or minutes the stager left
// unlabelled) on top as "Unstaged", so each bar is still the night's full asleep time. The Sleep tab's
// "Asleep duration" card draws the last 30 nights; the Trends screen draws the selected range, as nightly
// bars up to three months and as seven-day averages beyond that.

enum SleepStageTrend {
    /// One bar: a night, or the nightly average over a seven-day window. Hours.
    struct Bar: Identifiable, Equatable {
        /// Local midnight of the night's day, or the window's first day.
        var start: Date
        var deep: Double
        var rem: Double
        var light: Double
        var unstaged: Double
        /// Nights averaged (1 for a single night).
        var nights: Int
        var id: Date { start }
        var total: Double { deep + rem + light + unstaged }
    }

    enum Stage: String, CaseIterable {
        case deep = "Deep", rem = "REM", light = "Light", unstaged = "Unstaged"

        var color: Color {
            switch self {
            case .deep: return StrandPalette.sleepStageColor(.deep)
            case .rem: return StrandPalette.sleepStageColor(.rem)
            case .light: return StrandPalette.sleepStageColor(.light)
            case .unstaged: return StrandPalette.textTertiary.opacity(0.5)
            }
        }

        func hours(_ b: Bar) -> Double {
            switch self {
            case .deep: return b.deep
            case .rem: return b.rem
            case .light: return b.light
            case .unstaged: return b.unstaged
            }
        }
    }

    /// Below this, the gap between the total and the stages is rounding, not a stage of its own.
    static let unstagedFloorMin = 5.0

    /// The night's bar, or nil when it has no asleep time.
    static func night(_ d: DailyMetric) -> Bar? {
        guard let total = d.totalSleepMin, total > 0, let date = NutritionHistory.date(d.day) else { return nil }
        let deep = max(0, d.deepMin ?? 0), rem = max(0, d.remMin ?? 0), light = max(0, d.lightMin ?? 0)
        let rest = total - (deep + rem + light)
        return Bar(start: date, deep: deep / 60, rem: rem / 60, light: light / 60,
                   unstaged: rest >= unstagedFloorMin ? rest / 60 : 0, nights: 1)
    }

    /// Nights from the last `days` calendar days ending with `endDay`, oldest first; nil `days` means all.
    static func nights(_ days: [DailyMetric], last count: Int?, endDay: Date = Date(),
                       calendar cal: Calendar = .current) -> [Bar] {
        let end = cal.startOfDay(for: endDay)
        let first = count.flatMap { cal.date(byAdding: .day, value: -($0 - 1), to: end) }
        return days.compactMap(night)
            .filter { n in n.start <= end && (first.map { n.start >= $0 } ?? true) }
            .sorted { $0.start < $1.start }
    }

    /// `count` back-to-back seven-day windows, the newest ending with `endDay`, oldest first, each the average
    /// night of the nights it holds. Windows with no nights are left out.
    static func weeks(_ days: [DailyMetric], count: Int, endDay: Date = Date(),
                      calendar cal: Calendar = .current) -> [Bar] {
        guard let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: endDay)) else { return [] }
        let starts = (1...max(count, 1)).reversed().compactMap { cal.date(byAdding: .day, value: -7 * $0, to: end) }
        var groups: [Int: [Bar]] = [:]
        for n in days.compactMap(night) where n.start < end {
            guard let i = starts.lastIndex(where: { $0 <= n.start }) else { continue }
            groups[i, default: []].append(n)
        }
        return groups.keys.sorted().compactMap { i in
            guard let g = groups[i], !g.isEmpty else { return nil }
            let k = Double(g.count)
            return Bar(start: starts[i], deep: g.map(\.deep).reduce(0, +) / k, rem: g.map(\.rem).reduce(0, +) / k,
                       light: g.map(\.light).reduce(0, +) / k, unstaged: g.map(\.unstaged).reduce(0, +) / k,
                       nights: g.count)
        }
    }
}

/// The stacked bars. `weekly` labels each bar by its window's first day instead of drawing it on a day axis.
/// The legend's chips toggle stages: tap Light, REM and Unstaged off to see deep sleep alone, tap them back
/// on for the stack. The last stage showing can't be switched off.
struct SleepStagesChart: View {
    let bars: [SleepStageTrend.Bar]
    var weekly = false
    var height: CGFloat = NoopMetrics.chartHeight
    @State private var hidden: Set<SleepStageTrend.Stage> = []

    var body: some View {
        let stages = SleepStageTrend.Stage.allCases.filter { s in bars.contains { s.hours($0) > 0 } }
        let shown = stages.filter { !hidden.contains($0) }
        VStack(spacing: 6) {
            chart(stages: stages, shown: shown)
                .frame(maxHeight: .infinity)
            legend(stages)
        }
        .frame(height: height)
    }

    private func legend(_ stages: [SleepStageTrend.Stage]) -> some View {
        HStack(spacing: 6) {
            ForEach(stages, id: \.self) { s in
                let on = !hidden.contains(s)
                Button {
                    if on {
                        if stages.count - hidden.count > 1 { hidden.insert(s) }
                    } else {
                        hidden.remove(s)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(on ? s.color : Color.clear)
                            .overlay(Circle().stroke(s.color, lineWidth: 1.5))
                            .frame(width: 8, height: 8)
                        Text(s.rawValue)
                            .font(StrandFont.caption)
                            .foregroundStyle(on ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                            .strikethrough(!on)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(on ? s.color.opacity(0.15) : Color.clear))
                    .overlay(Capsule().stroke(StrandPalette.hairlineStrong, lineWidth: on ? 0 : 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(s.rawValue))
                .accessibilityValue(Text(on ? "Shown" : "Hidden"))
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func chart(stages: [SleepStageTrend.Stage], shown: [SleepStageTrend.Stage]) -> some View {
        Chart {
            ForEach(bars) { b in
                // Declared bottom-up: deep, REM, light, unstaged.
                ForEach(shown, id: \.self) { s in
                    if weekly {
                        BarMark(x: .value("Seven days from", label(b)), y: .value("Hours", s.hours(b)))
                            .foregroundStyle(by: .value("Stage", s.rawValue))
                    } else {
                        BarMark(x: .value("Night", b.start, unit: .day), y: .value("Hours", s.hours(b)))
                            .foregroundStyle(by: .value("Stage", s.rawValue))
                    }
                }
            }
        }
        // The full domain, so a stage keeps its colour while others are hidden.
        .chartForegroundStyleScale(domain: stages.map(\.rawValue), range: stages.map(\.color))
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine()
                AxisValueLabel { if let h = v.as(Double.self) { Text("\(Int(h))h") } }
            }
        }
        .chartXAxis {
            if weekly {
                AxisMarks(values: shownLabels) { _ in AxisValueLabel() }
            } else {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
        }
        .accessibilityLabel(Text("Hours asleep per night by sleep stage"))
    }

    private func label(_ b: SleepStageTrend.Bar) -> String { b.start.formatted(.dateTime.day().month(.abbreviated)) }

    /// About six labels, always including the newest bar.
    private var shownLabels: [String] {
        let labels = bars.map(label)
        let every = max(1, Int((Double(labels.count) / 6).rounded(.up)))
        return labels.enumerated().filter { ($0.offset - (labels.count - 1)) % every == 0 }.map(\.element)
    }
}

/// The Trends card: stages per night over the selected range.
struct SleepStagesTrendCard: View {
    /// The range's length in days; nil for all history.
    let rangeDays: Int?
    @EnvironmentObject private var repo: Repository

    /// Nightly bars up to this many days; seven-day averages beyond.
    static let nightlyLimit = 92

    var body: some View {
        let weekly = (rangeDays ?? Int.max) > Self.nightlyLimit
        let windows = min(max((rangeDays ?? 364) / 7, 4), 52)
        let bars = weekly ? SleepStageTrend.weeks(repo.days, count: windows)
                          : SleepStageTrend.nights(repo.days, last: rangeDays)
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sleep stages over time").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        Text(weekly ? String(localized: "Average night per 7 days, last \(windows) × 7 days")
                                    : String(localized: "Hours asleep per night, last \(rangeDays ?? 0) days"))
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer()
                    if !bars.isEmpty {
                        let k = Double(bars.count)
                        Text(String(format: "%.1f h avg", bars.map(\.total).reduce(0, +) / k))
                            .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                if bars.count >= 2 {
                    SleepStagesChart(bars: bars, weekly: weekly, height: 210)
                    averages(bars)
                } else {
                    Text("Not enough nights yet.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    /// "Deep 1.2 h · REM 1.6 h · Light 3.9 h": the average night over the bars.
    private func averages(_ bars: [SleepStageTrend.Bar]) -> some View {
        let k = Double(bars.count)
        let parts = SleepStageTrend.Stage.allCases.compactMap { s -> String? in
            let h = bars.map { s.hours($0) }.reduce(0, +) / k
            return h > 0.05 ? "\(s.rawValue) \(String(format: "%.1f", h)) h" : nil
        }
        return Text(parts.joined(separator: " · "))
            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
    }
}
