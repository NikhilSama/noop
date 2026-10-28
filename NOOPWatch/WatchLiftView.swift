import SwiftUI
import StrandDesign
import WatchConnectivity
import HealthKit

// nikhil/custom — the watch Lift Log screen: a hybrid of the workout readout (session time + wrist heart
// rate, from the HealthKit workout the phone's Lift Log started) and the Lift Log's current set.
//
// The phone stays the brain: it sends the set in focus with its numbers prefilled (`LiftWatchState`), and
// the button sends back the set with whatever the crown changed (`LiftWatchAction`), which the phone
// applies and advances exactly like its own big button. Tap weight or reps to pick what the crown edits.

/// Holds the latest session state pushed by the phone.
final class WatchLiftStore: ObservableObject {
    static let shared = WatchLiftStore()

    @Published private(set) var state: LiftWatchState?
    /// True while a button press is on its way to the phone, so a double tap can't advance twice.
    @Published private(set) var sending = false

    /// Apply a phone payload (message or reply). An empty value means no session.
    func receive(_ payload: [String: Any]) {
        guard let data = payload[LiftWatchState.messageKey] as? Data else { return }
        let decoded = data.isEmpty ? nil : LiftWatchState.decode(data)
        DispatchQueue.main.async {
            self.state = decoded
            self.sending = false
        }
    }

    func requestState() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage([LiftWatchAction.requestKey: true], replyHandler: { [weak self] reply in
            self?.receive(reply)
        }, errorHandler: nil)
    }

    func send(_ action: LiftWatchAction) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        sending = true
        session.sendMessage([LiftWatchAction.messageKey: action.encoded()], replyHandler: { _ in },
                            errorHandler: { [weak self] _ in DispatchQueue.main.async { self?.sending = false } })
        // The phone answers with a fresh state; clear the guard regardless after a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.sending = false }
    }
}

struct WatchLiftView: View {
    @ObservedObject private var lift = WatchLiftStore.shared
    @ObservedObject private var workout = WatchWorkoutSession.shared

    private enum Field { case weight, reps }
    @State private var field: Field = .weight
    @State private var crown: Double = 0
    @State private var weight: Double = 0      // display unit
    @State private var reps: Double = 0
    @State private var shownSlot: String = ""

    var body: some View {
        Group {
            if let s = lift.state, s.stage != .finished {
                session(s)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "dumbbell.fill").font(.system(size: 24))
                        .foregroundStyle(StrandPalette.effortColor)
                    Text(lift.state == nil ? "Start a Lift Log on your iPhone" : "All sets done — finish on iPhone")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .onAppear { lift.requestState(); ensureWorkout() }
        .onChange(of: lift.state) { _, new in adopt(new); ensureWorkout() }
    }

    // MARK: Layout

    private func session(_ s: LiftWatchState) -> some View {
        VStack(spacing: 4) {
            header
            workoutStatus
            VStack(spacing: 0) {
                Text(s.exercise)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(subtitle(s))
                        .font(StrandFont.footnote)
                        .foregroundStyle(restColor(s))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            HStack(spacing: 6) {
                numberBox(LiftWatchView.trim(weight), unit: s.imperial ? "lb" : "kg", selected: field == .weight)
                    .onTapGesture { select(.weight) }
                numberBox("\(Int(reps))", unit: "reps", selected: field == .reps)
                    .onTapGesture { select(.reps) }
            }
            .focusable()
            .digitalCrownRotation($crown, from: -10_000, through: 10_000, by: 1,
                                  sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
            .onChange(of: crown) { old, new in nudge(by: new - old, step: s.weightStep) }
            Button {
                lift.send(LiftWatchAction(
                    exerciseIndex: s.exerciseIndex, setIndex: s.setIndex,
                    weightKg: s.imperial ? weight / 2.2046226218 : weight,
                    reps: Int(reps)))
            } label: {
                Text(s.stage == .working ? "Done" : "Start set")
                    .font(StrandFont.subhead)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(s.stage == .working ? StrandPalette.recoveryColor(100) : StrandPalette.effortColor)
            .disabled(lift.sending)
        }
        .padding(.horizontal, 4)
    }

    /// If the phone's Lift Log is running but the watch workout is not (the launch was missed or failed),
    /// start it here, so time, heart rate and the Health/Activity workout still happen.
    private func ensureWorkout() {
        guard let s = lift.state, s.stage != .finished, workout.phase == .idle else { return }
        WatchDiag.log("lift screen: session running but workout idle; starting it")
        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining
        config.locationType = .indoor
        workout.startFromPhone(config)
    }

    /// Shown under the header when the watch workout is not recording, with the way to fix it.
    @ViewBuilder private var workoutStatus: some View {
        switch workout.phase {
        case .active, .paused, .ending, .saved:
            EmptyView()
        case .denied, .unavailable:
            Text("Health access off: Watch Settings → Health → NOOP")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.recoveryColor(0))
                .lineLimit(2).multilineTextAlignment(.center)
        case .requesting:
            Text("Allow Health access to record")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.effortColor)
        case .idle:
            Button("Workout not recording — tap to start") { ensureWorkout() }
                .font(StrandFont.caption).buttonStyle(.plain)
                .foregroundStyle(StrandPalette.effortColor)
        }
    }

    /// Session time and wrist heart rate, from the HealthKit workout.
    private var header: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(WatchWorkoutView.clock(workout.liveElapsed()))
                    .font(StrandFont.rounded(15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            Spacer()
            HStack(spacing: 2) {
                Image(systemName: "heart.fill").font(.system(size: 11))
                Text(workout.bpm.map(String.init) ?? "--")
                    .font(StrandFont.rounded(15, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(StrandPalette.recoveryColor(0))
        }
    }

    private func numberBox(_ value: String, unit: String, selected: Bool) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(StrandFont.rounded(24, weight: .bold))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(StrandPalette.textPrimary)
            Text(unit).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 8)
            .stroke(selected ? StrandPalette.effortColor : StrandPalette.hairlineStrong, lineWidth: selected ? 2 : 1))
    }

    private func subtitle(_ s: LiftWatchState) -> String {
        let set = "Set \(s.setIndex)/\(s.setCount) · Ex \(s.exerciseIndex + 1)/\(s.exerciseCount)"
        guard s.stage == .resting, let end = s.restEndsAt else { return set }
        let left = max(0, end - Int(Date().timeIntervalSince1970))
        return left > 0 ? "Rest \(WatchWorkoutView.clock(TimeInterval(left))) · next \(set)" : "Rest over · next \(set)"
    }

    private func restColor(_ s: LiftWatchState) -> Color {
        s.stage == .resting ? StrandPalette.effortColor : StrandPalette.textSecondary
    }

    // MARK: Editing

    private func select(_ f: Field) { field = f }

    private func nudge(by delta: Double, step: Double) {
        guard delta != 0 else { return }
        let ticks = delta.rounded()
        switch field {
        case .weight: weight = max(0, (weight + ticks * step) / step).rounded() * step
        case .reps: reps = max(0, reps + ticks)
        }
    }

    /// Take the phone's numbers when the focus moves to a new set; keep crown edits while it stays.
    private func adopt(_ s: LiftWatchState?) {
        guard let s else { return }
        let key = "\(s.exerciseIndex)-\(s.setIndex)-\(s.stage.rawValue)"
        guard key != shownSlot else { return }
        shownSlot = key
        let kg = s.weightKg ?? 0
        weight = s.imperial ? (kg * 2.2046226218).rounded() : kg
        reps = Double(s.reps ?? 0)
        field = .weight
    }
}

enum LiftWatchView {
    static func trim(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}
