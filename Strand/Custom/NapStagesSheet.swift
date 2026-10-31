import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// nikhil/custom — a nap's stage breakdown, opened by tapping its row on the Sleep tab's Naps card. The nap
// is its own session row with its own staged `stagesJSON` (from the add/edit path or the detector); the
// night's stage card never draws it, so this sheet does: hypnogram, asleep / efficiency / heart rate, and
// one row per stage. A nap saved before the strap synced holds a single awake placeholder until the
// post-sync self-heal re-stages it; that case gets a note instead of an all-awake chart.
struct NapStagesSheet: View {
    let nap: CachedSleepSession
    let onEdit: () -> Void

    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SleepChartStyle.storageKey) private var chartStyleRaw = SleepChartStyle.classic.rawValue
    @State private var highlighted: SleepStage?
    @State private var heart: (avg: Int, low: Int)?

    private var decoded: (stages: Stages, intervals: [SleepInterval])? {
        SleepView.decodeSegments(nap.stagesJSON, sessionStart: nap.effectiveStartTs)
    }

    /// Only a placeholder (one awake block, no sleep) means the raw hadn't synced when the nap was saved.
    private var isPlaceholder: Bool {
        guard let d = decoded else { return true }
        return d.stages.asleep <= 0 && d.intervals.count <= 1
    }

    private var start: Date { Date(timeIntervalSince1970: TimeInterval(nap.effectiveStartTs)) }
    private var windowMinutes: Double { Double(nap.endTs - nap.effectiveStartTs) / 60 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                header
                if let d = decoded, !isPlaceholder {
                    stats(d.stages)
                    chartCard(d)
                } else {
                    NoopCard(tint: StrandPalette.restColor) {
                        Text("No stages yet. They appear after your strap syncs the data for this nap; open this again then.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Stages are staged on-device from your strap's motion, heart rate and breathing. The stager is built for nights, so on a short nap the deep / REM split is approximate.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Edit times") {
                        dismiss()
                        onEdit()
                    }
                    .buttonStyle(.noopGhost)
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.noopPrimary)
                }
            }
            .padding(NoopMetrics.screenPadding)
        }
        .frame(minWidth: 360, minHeight: 480)
        .background(NoopChromeSurface())
        .task(id: nap.startTs) { await loadHeart() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
            Text("Nap").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text("\(start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) · \(Night.clockString(nap.effectiveStartTs))-\(Night.clockString(nap.endTs)) · \(Self.duration(windowMinutes))")
                .font(StrandFont.subhead).monospacedDigit()
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private func stats(_ s: Stages) -> some View {
        HStack(alignment: .top, spacing: 0) {
            stat("Asleep", Self.duration(s.asleep))
            stat("Efficiency", s.total > 0 ? "\(Int((s.asleep / s.total * 100).rounded()))%" : "–")
            stat("Avg HR", heart.map { "\($0.avg)" } ?? "–")
            stat("Lowest HR", heart.map { "\($0.low)" } ?? "–")
        }
    }

    private func stat(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).strandOverline()
            Text(value).font(StrandFont.number(22)).foregroundStyle(StrandPalette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func chartCard(_ d: (stages: Stages, intervals: [SleepInterval])) -> some View {
        // Classic is a per-stage-rows layout the shared hypnogram doesn't draw; a nap uses the filled chart
        // in NOOP colours for it, and the user's ramp for the other styles.
        let style = SleepChartStyle.resolve(chartStyleRaw)
        let s = d.stages
        return NoopCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Stage breakdown").strandOverline()
                Hypnogram(intervals: d.intervals,
                          height: NoopMetrics.chartHeight,
                          showsStageAxis: false,
                          showsHover: true,
                          nightStart: start,
                          showsTimeAxis: true,
                          // A nap is short: absorb only sub-minute flickers, not the night chart's 5 min.
                          smoothingSeconds: 60,
                          highlightedStage: highlighted,
                          filled: style != .ribbon,
                          stagePalette: style.stagePalette)
                let pct = StagePercentages.wholePercentages([s.awake, s.light, s.deep, s.rem]) ?? [0, 0, 0, 0]
                VStack(spacing: NoopMetrics.space1) {
                    stageRow(.awake, s.awake, total: s.total, percent: pct[0], palette: style.stagePalette)
                    stageRow(.rem, s.rem, total: s.total, percent: pct[3], palette: style.stagePalette)
                    stageRow(.light, s.light, total: s.total, percent: pct[1], palette: style.stagePalette)
                    stageRow(.deep, s.deep, total: s.total, percent: pct[2], palette: style.stagePalette)
                }
            }
        }
    }

    /// Same reading as the night's breakdown rows; tap to highlight that stage on the chart.
    private func stageRow(_ stage: SleepStage, _ minutes: Double, total: Double, percent: Int,
                          palette: SleepStagePalette) -> some View {
        let color = StrandPalette.sleepStageColor(stage, palette: palette)
        let selected = highlighted == stage
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color)
                .frame(width: 12, height: 12)
            Text(stage.label.uppercased())
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 56, alignment: .leading)
            Text("\(percent)%")
                .font(StrandFont.captionNumber).foregroundStyle(color)
                .frame(width: 38, alignment: .leading)
            PipBar(value: total > 0 ? min(1, minutes / total) * 100 : 0, segments: 20, tint: color, height: 8)
            Text(Self.duration(minutes))
                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(selected ? 0.14 : 0)))
        .opacity(highlighted != nil && !selected ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(StrandMotion.fade) { highlighted = selected ? nil : stage } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stage.label): \(Self.duration(minutes)), \(percent) percent of the nap")
    }

    private func loadHeart() async {
        let bpm = await repo.hrSamples(from: nap.effectiveStartTs, to: nap.endTs).map(\.bpm).filter { $0 > 0 }
        guard !bpm.isEmpty else { heart = nil; return }
        heart = (Int((Double(bpm.reduce(0, +)) / Double(bpm.count)).rounded()), bpm.min()!)
    }

    static func duration(_ minutes: Double) -> String {
        let m = max(0, Int(minutes.rounded()))
        return m < 60 ? String(localized: "\(m)m") : String(localized: "\(m / 60)h \(m % 60)m")
    }

    /// Asleep minutes of a nap row, or nil when it holds no real stages yet (placeholder / imported).
    static func asleepMinutes(_ nap: CachedSleepSession) -> Double? {
        guard let d = SleepView.decodeSegments(nap.stagesJSON, sessionStart: nap.effectiveStartTs),
              d.stages.asleep > 0 else { return nil }
        return d.stages.asleep
    }
}

/// Sheet identity for a nap row (CachedSleepSession isn't Identifiable); keyed on the immutable detected start.
struct NapStagesTarget: Identifiable {
    let nap: CachedSleepSession
    var id: Int { nap.startTs }
}
