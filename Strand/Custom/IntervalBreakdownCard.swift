import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// nikhil/custom — the interval breakdown on a workout's detail screen: three headline figures against the
// last session of the same activity and plan, then one row per block. Renders nothing for a workout that
// wasn't run in interval mode.
struct IntervalBreakdownCard: View {
    let row: WorkoutRow
    let zones: HRZoneSet

    @EnvironmentObject private var repo: Repository
    @State private var loaded: IntervalSummary.Loaded?

    var body: some View {
        Group {
            if let loaded { content(loaded) }
        }
        .task(id: row.startTs) {
            loaded = await IntervalSummary.load(startTs: row.startTs, sport: row.sport, repo: repo, zones: zones)
        }
    }

    private func content(_ l: IntervalSummary.Loaded) -> some View {
        let c = l.current
        let z = c.entry.plan.workZone
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Intervals", overline: LocalizedStringKey(c.entry.plan.summary),
                          trailing: l.previousStart.map { String(localized: "vs \(Self.dateLabel($0))") })
            NoopCard(tint: StrandPalette.effortColor) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 0) {
                        stat(String(localized: "Z\(z) per rep"),
                             c.avgWorkTargetSeconds.map(Self.clock),
                             last: l.previous?.avgWorkTargetSeconds.map(Self.clock),
                             better: compare(c.avgWorkTargetSeconds, l.previous?.avgWorkTargetSeconds, higherIsBetter: true))
                        stat(String(localized: "Work HR"),
                             c.avgWorkHr.map { "\($0)" },
                             last: l.previous?.avgWorkHr.map { "\($0)" },
                             better: nil)
                        stat(String(localized: "Recovery 1 min"),
                             c.avgRecoveryBpm.map(Self.drop),
                             last: l.previous?.avgRecoveryBpm.map(Self.drop),
                             better: compare(c.avgRecoveryBpm.map(Double.init), l.previous?.avgRecoveryBpm.map(Double.init),
                                             higherIsBetter: true))
                    }
                    Divider().overlay(StrandPalette.hairline)
                    VStack(spacing: 8) {
                        ForEach(c.blocks) { blockRow($0) }
                    }
                    Divider().overlay(StrandPalette.hairline)
                    Text(footnote(l))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func footnote(_ l: IntervalSummary.Loaded) -> String {
        let base = String(localized: "Time in zone counts the whole block, including the first minute while your heart rate climbs or settles. Recovery is how far your heart rate fell in the first minute of each rest; a bigger drop is fitter.")
        guard l.previous == nil else { return base }
        return base + " " + String(localized: "The comparison appears after your next session of the same activity and plan.")
    }

    /// nil = no comparison, true = better than last time, false = worse.
    private func compare(_ now: Double?, _ last: Double?, higherIsBetter: Bool) -> Bool? {
        guard let now, let last, now != last else { return nil }
        return (now > last) == higherIsBetter
    }

    private func stat(_ label: String, _ value: String?, last: String?, better: Bool?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).strandOverline()
            Text(value ?? "–")
                .font(StrandFont.number(24))
                .foregroundStyle(better == nil ? StrandPalette.textPrimary
                                 : better! ? StrandPalette.statusPositive : StrandPalette.statusWarning)
            if let last {
                Text("last \(last)")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func blockRow(_ b: IntervalSummary.Block) -> some View {
        let color = b.kind == .work ? StrandPalette.effortColor : StrandPalette.restColor
        return HStack(spacing: NoopMetrics.space2) {
            Text("\(b.kind == .work ? "W" : "R")\(b.round)")
                .font(StrandFont.captionNumber.weight(.bold))
                .foregroundStyle(color)
                .frame(width: 30, alignment: .leading)
            Text(IntervalPreset.clock(b.seconds) + (b.skipped ? "*" : ""))
                .font(StrandFont.captionNumber).monospacedDigit()
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 46, alignment: .leading)
            Text(b.avgHr.map { "\($0)" } ?? "–")
                .font(StrandFont.captionNumber).monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 34, alignment: .trailing)
            Text(b.peakHr.map { "/\($0)" } ?? "")
                .font(StrandFont.captionNumber).monospacedDigit()
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 38, alignment: .leading)
            // Share of the block in its target zone.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.textPrimary.opacity(0.08))
                    Capsule().fill(StrandPalette.hrZoneColor(b.targetZone))
                        .frame(width: geo.size.width * b.targetFraction)
                }
            }
            .frame(height: 8)
            Text("\(Int((b.targetFraction * 100).rounded()))% Z\(b.targetZone)")
                .font(StrandFont.captionNumber).monospacedDigit()
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 62, alignment: .trailing)
            Text(b.recoveryBpm.map(Self.drop) ?? "")
                .font(StrandFont.captionNumber).monospacedDigit()
                .foregroundStyle(StrandPalette.statusPositive)
                .frame(width: 34, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibility(b)))
    }

    private func accessibility(_ b: IntervalSummary.Block) -> String {
        var s = "\(b.kind == .work ? "Work" : "Rest") \(b.round), \(IntervalPreset.clock(b.seconds))"
        if let hr = b.avgHr { s += ", average \(hr) bpm" }
        s += ", \(Int((b.targetFraction * 100).rounded())) percent in zone \(b.targetZone)"
        if let r = b.recoveryBpm { s += ", heart rate fell \(r) bpm in the first minute" }
        return s
    }

    /// "−28" for a 28 bpm fall; "+3" if the heart rate rose.
    private static func drop(_ bpm: Int) -> String { bpm >= 0 ? "−\(bpm)" : "+\(-bpm)" }

    private static func clock(_ seconds: Double) -> String { IntervalPreset.clock(Int(seconds.rounded())) }

    private static func dateLabel(_ d: Date) -> String {
        d.formatted(.dateTime.day().month(.abbreviated))
    }
}
