import SwiftUI
import StrandDesign

// nikhil/custom — the live workout's hero in interval mode: one ring that is the block clock (fill = time
// through the block, colour = work / rest / cooldown) around the live heart rate (tinted by its zone, so a
// match with the block's target zone reads at a glance), the block line under it, and Skip / Pause.
struct LiveIntervalHero: View {
    @EnvironmentObject private var model: AppModel
    let session: IntervalSession
    let zone: Int

    private let diameter: CGFloat = 260
    private let lineWidth: CGFloat = 18

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            VStack(spacing: NoopMetrics.space4) {
                ring(now: now)
                blockLine(now: now)
                if !session.finished { controls }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var phaseColor: Color {
        if session.finished { return StrandPalette.statusPositive }
        return session.kind == .work ? StrandPalette.effortColor : StrandPalette.restColor
    }

    private var phaseLabel: String {
        if session.finished { return String(localized: "COOLDOWN") }
        return session.kind == .work ? String(localized: "WORK") : String(localized: "REST")
    }

    private func ring(now: Date) -> some View {
        let fraction = session.progress(at: now)
        let hrTint = zone >= 1 ? StrandPalette.hrZoneColor(zone) : StrandPalette.textPrimary
        return ZStack {
            Circle()
                .stroke(StrandPalette.textPrimary.opacity(0.10),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: max(0.0001, CGFloat(fraction)))
                .rotation(.degrees(-90))
                .stroke(phaseColor.opacity(session.isPaused ? 0.45 : 1),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .animation(.linear(duration: 1), value: fraction)
            VStack(spacing: 2) {
                Text(phaseLabel)
                    .font(StrandFont.overline).tracking(2)
                    .foregroundStyle(phaseColor)
                if let bpm = model.bpm {
                    CountUpText(value: Double(bpm), format: { "\(Int($0.rounded()))" },
                                font: StrandFont.rounded(72, weight: .semibold), color: hrTint)
                } else {
                    Text("—")
                        .font(StrandFont.rounded(72, weight: .semibold))
                        .foregroundStyle(hrTint)
                }
                Text(zone >= 1 ? "bpm · Z\(zone)" : "bpm")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText(now: now)))
    }

    /// "Z3 target · 2:41 left · round 3/6" and "Next: rest 3:00 · Z2"; in cooldown, the finished plan.
    private func blockLine(now: Date) -> some View {
        VStack(spacing: NoopMetrics.space1) {
            if session.finished {
                Text("Intervals done · \(session.plan.summary)")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Still recording. End the workout when you've cooled down.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                HStack(spacing: NoopMetrics.space2) {
                    Text(IntervalPreset.clock(session.remaining(at: now)))
                        .font(StrandFont.number(34)).monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                        .contentTransition(.numericText())
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Z\(session.targetZone) target")
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.hrZoneColor(session.targetZone))
                        Text(roundText)
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                if let next = session.next {
                    Text("Next: \(next.kind == .work ? String(localized: "work") : String(localized: "rest")) \(IntervalPreset.clock(next.seconds)) · Z\(next.zone)")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    Text("Last block, then cooldown")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .multilineTextAlignment(.center)
    }

    private var roundText: String {
        if let rounds = session.plan.rounds { return String(localized: "Round \(session.round)/\(rounds)") }
        return String(localized: "Round \(session.round)")
    }

    private var controls: some View {
        HStack(spacing: NoopMetrics.space3) {
            NoopButton(session.isPaused ? "Resume" : "Pause",
                       systemImage: session.isPaused ? "play.fill" : "pause.fill",
                       kind: .secondary, fullWidth: true) {
                model.toggleIntervalPause()
            }
            NoopButton("Skip", systemImage: "forward.end.fill", kind: .primary, fullWidth: true) {
                model.skipInterval()
            }
        }
    }

    private func accessibilityText(now: Date) -> String {
        let hr = model.bpm.map { "\($0) bpm" } ?? ""
        if session.finished { return "Cooldown. \(hr)" }
        return "\(phaseLabel), \(session.remaining(at: now)) seconds left, target zone \(session.targetZone). \(hr)"
    }
}
