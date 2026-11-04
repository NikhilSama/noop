import SwiftUI
import StrandDesign
import StrandAnalytics

// nikhil/custom — edit the hydration plan: the daily goal (automatic or fixed), the standard amount counted
// every day without tapping, the glass one tap logs, the window the rest is paced over, and the hourly
// reminders. Saving re-plans the reminders and updates the watch.
struct HydrationPlanSheet: View {
    let onSave: () -> Void

    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss

    @State private var fixedGoal = HydrationPlan.goalOverrideML > 0
    @State private var goalML = HydrationPlan.goalOverrideML > 0 ? HydrationPlan.goalOverrideML : 3000
    @State private var standardML = HydrationPlan.standardML
    @State private var glassML = HydrationPlan.glassML
    @State private var startHour = HydrationPlan.windowStartHour
    @State private var endHour = HydrationPlan.windowEndHour
    @State private var reminders = HydrationPlan.remindersOn
    @State private var permissionDenied = false

    private var trackedML: Int { HydrationPace.trackedTarget(goalML: fixedGoal ? goalML : automaticGoal, standardML: standardML) }
    private var automaticGoal: Int { HydrationGoal.dailyGoalML(sex: HydrationSync.profileSex(), effort: repo.today?.strain) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                Text("Hydration plan").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)

                section("Daily goal") {
                    Toggle("Set my own goal", isOn: $fixedGoal).tint(StrandPalette.accent)
                    if fixedGoal {
                        amountStepper("Goal", value: $goalML, range: 500...8000, step: 50)
                    } else {
                        Text("Automatic: \(HydrationView.litres(automaticGoal)) L today, from your profile and effort.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }
                }

                section("Standard amount") {
                    amountStepper("Every day", value: $standardML, range: 0...5000, step: 50)
                    Text("What you drink every day without thinking about it (morning water, coffee). It's added to each day automatically, so you only track the rest. Delete it from a day's drinks if you skipped it.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Glass") {
                    amountStepper("One tap logs", value: $glassML, range: 50...1000, step: 10)
                    Text("Used by the Log a glass button, the + menu, the watch and the reminder's Log button.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Pace") {
                    HStack {
                        Text("From").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        Spacer()
                        hourPicker($startHour, range: 0...22)
                    }
                    HStack {
                        Text("Until").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        Spacer()
                        hourPicker($endHour, range: (startHour + 1)...24)
                    }
                    Toggle("Hourly reminders", isOn: $reminders).tint(StrandPalette.accent)
                    Text("Tracked \(HydrationView.litres(trackedML)) L over \(max(1, endHour - startHour)) hours is about \(trackedML / max(1, endHour - startHour)) ml an hour. With reminders on, you get a nudge on the hour (it buzzes your watch when your phone is locked) only when you're behind that pace.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if permissionDenied {
                        Text("Notifications are off for this app. Turn them on in Settings to get reminders.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.statusWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: NoopMetrics.gap) {
                    NoopButton("Cancel", kind: .secondary, fullWidth: true) { dismiss() }
                    NoopButton("Save", kind: .primary, fullWidth: true) { Task { await save() } }
                }
            }
            .padding(NoopMetrics.screenPadding)
        }
        .frame(minWidth: 360, minHeight: 520)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .onChangeCompat(of: startHour) { s in if endHour <= s { endHour = s + 1 } }
    }

    private func section<V: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(title).strandOverline()
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoopPanelSurface(cornerRadius: 18))
    }

    private func amountStepper(_ label: LocalizedStringKey, value: Binding<Int>, range: ClosedRange<Int>, step: Int) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Text("\(value.wrappedValue) ml").font(StrandFont.headline).monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
            }
        }
    }

    private func hourPicker(_ value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        Picker("", selection: value) {
            ForEach(Array(range), id: \.self) { h in Text(HydrationView.hour(h)).tag(h) }
        }
        .labelsHidden()
        .tint(StrandPalette.accent)
    }

    private func save() async {
        let d = UserDefaults.standard
        d.set(fixedGoal ? goalML : 0, forKey: HydrationPlan.goalOverrideKey)
        d.set(glassML, forKey: HydrationPlan.glassKey)
        d.set(startHour, forKey: HydrationPlan.windowStartKey)
        d.set(min(max(endHour, startHour + 1), 24), forKey: HydrationPlan.windowEndKey)
        if reminders, !HydrationPlan.remindersOn {
            permissionDenied = !(await HydrationReminders.requestPermission())
            if permissionDenied { return }
        }
        d.set(reminders, forKey: HydrationPlan.remindersKey)

        // A changed standard amount also changes today's standard entry, so today agrees with the plan.
        let oldStandard = HydrationPlan.standardML
        d.set(standardML, forKey: HydrationPlan.standardKey)
        if standardML != oldStandard,
           let today = repo.hydrationEntries().first(where: { $0.isStandard == true }) {
            await repo.updateHydrationEntry(id: today.id, amountMl: standardML)
        }
        await HydrationSync.run(repo)
        onSave()
        dismiss()
    }
}
