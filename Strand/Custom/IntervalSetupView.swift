import SwiftUI
import StrandDesign

// nikhil/custom — the interval setup screen, pushed from the activity picker when the activity is in interval
// mode (or the picker's Intervals toggle is on). Opens on that activity's last plan; Start remembers the plan
// and keeps the activity in interval mode, "Skip intervals" takes it out and starts a plain workout.
struct IntervalSetupView: View {
    @EnvironmentObject private var model: AppModel
    let sport: String
    let onStart: (_ plan: IntervalPlan?) -> Void

    @State private var plan: IntervalPlan
    @State private var hapticsOn = HapticPrefs.enabled(HapticPrefs.intervals)

    init(sport: String, onStart: @escaping (_ plan: IntervalPlan?) -> Void) {
        self.sport = sport
        self.onStart = onStart
        _plan = State(initialValue: IntervalWorkoutPrefs.plan(sport: sport))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.space5) {
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text("\(sport) intervals")
                        .font(StrandFont.rounded(30, weight: .bold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(summaryLine)
                        .font(StrandFont.subhead).monospacedDigit()
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                presets
                NoopCard(padding: NoopMetrics.cardInnerPadding) {
                    VStack(spacing: NoopMetrics.space4) {
                        durationRow("Work", seconds: $plan.workSeconds, tint: StrandPalette.effortColor)
                        durationRow("Rest", seconds: $plan.restSeconds, tint: StrandPalette.restColor)
                        roundsRow
                        startWithRow
                    }
                }
                NoopCard(padding: NoopMetrics.cardInnerPadding) {
                    VStack(spacing: NoopMetrics.space4) {
                        zoneRow("Work zone", zone: $plan.workZone)
                        zoneRow("Rest zone", zone: $plan.restZone)
                    }
                }
                warnings
                VStack(spacing: NoopMetrics.space3) {
                    NoopButton("Start", systemImage: "play.fill", kind: .primary, fullWidth: true) {
                        IntervalWorkoutPrefs.save(plan, sport: sport)
                        IntervalWorkoutPrefs.setEnabled(true, sport: sport)
                        onStart(plan)
                    }
                    Button("Skip intervals") {
                        IntervalWorkoutPrefs.setEnabled(false, sport: sport)
                        onStart(nil)
                    }
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, NoopMetrics.space5)
            .padding(.vertical, NoopMetrics.space4)
        }
        .background { StrandPalette.surfaceBase.ignoresSafeArea() }
    }

    private var summaryLine: String {
        let total = plan.totalSeconds.map { " · \(IntervalPreset.clock($0)) + cooldown" } ?? " · until you end it"
        return plan.summary + total
    }

    // MARK: Presets

    private var presets: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NoopMetrics.space2) {
                ForEach(IntervalPresets.watch) { preset in
                    let selected = plan.matches(preset)
                    Button { plan = plan.applying(preset) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name).font(StrandFont.subhead.weight(.semibold))
                            Text(preset.summary).font(StrandFont.captionNumber)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        .padding(.horizontal, NoopMetrics.space3)
                        .padding(.vertical, NoopMetrics.space2)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .background(selected ? StrandPalette.effortColor.opacity(0.18) : StrandPalette.surfaceInset,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(selected ? StrandPalette.effortColor : StrandPalette.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Rows

    /// min:sec stepper: 15 s steps, 5 s under a minute (so 6 s / 4 s sprints still fit).
    private func durationRow(_ title: LocalizedStringKey, seconds: Binding<Int>, tint: Color) -> some View {
        HStack {
            Text(title).font(StrandFont.headline).foregroundStyle(tint)
            Spacer()
            stepButton("minus") { seconds.wrappedValue = max(5, seconds.wrappedValue - Self.step(below: seconds.wrappedValue)) }
            Text(IntervalPreset.clock(seconds.wrappedValue))
                .font(StrandFont.number(24)).monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(minWidth: 72)
            stepButton("plus") { seconds.wrappedValue = min(3_600, seconds.wrappedValue + Self.step(above: seconds.wrappedValue)) }
        }
    }

    static func step(above s: Int) -> Int { s < 60 ? 5 : 15 }
    static func step(below s: Int) -> Int { s <= 60 ? 5 : 15 }

    private var roundsRow: some View {
        VStack(spacing: NoopMetrics.space2) {
            HStack {
                Text("Rounds").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                stepButton("minus") { if let r = plan.rounds { plan.rounds = max(1, r - 1) } }
                    .disabled(plan.rounds == nil)
                Text(plan.rounds.map(String.init) ?? "∞")
                    .font(StrandFont.number(24)).monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(minWidth: 72)
                stepButton("plus") { if let r = plan.rounds { plan.rounds = min(30, r + 1) } }
                    .disabled(plan.rounds == nil)
            }
            Toggle(isOn: Binding(get: { plan.rounds == nil },
                                 set: { plan.rounds = $0 ? nil : 6 })) {
                Text("Until I end the workout").font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    private var startWithRow: some View {
        HStack {
            Text("Start with").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            Picker("Start with", selection: $plan.restFirst) {
                Text("Work").tag(false)
                Text("Rest").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 180)
        }
    }

    private func zoneRow(_ title: LocalizedStringKey, zone: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            HStack(spacing: NoopMetrics.space2) {
                ForEach(1...5, id: \.self) { z in
                    let selected = zone.wrappedValue == z
                    let color = StrandPalette.hrZoneColor(z)
                    Button { zone.wrappedValue = z } label: {
                        Text("Z\(z)")
                            .font(StrandFont.subhead.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .foregroundStyle(selected ? StrandPalette.surfaceBase : color)
                            .background(selected ? color : color.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .frame(width: 40, height: 40)
                .foregroundStyle(StrandPalette.textPrimary)
                .background(StrandPalette.surfaceInset, in: Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Warnings

    @ViewBuilder private var warnings: some View {
        if !hapticsOn {
            HStack {
                Label("Strap buzzes for intervals are off", systemImage: "bell.slash")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.statusWarning)
                Spacer()
                Button("Turn on") {
                    HapticPrefs.setEnabled(HapticPrefs.intervals, true)
                    hapticsOn = true
                }
                .font(StrandFont.footnote.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.effortColor)
            }
        }
        if !model.live.bonded {
            Label("Connect your strap for buzz cues. The phone still vibrates on the live screen.",
                  systemImage: "wave.3.right")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
    }
}
