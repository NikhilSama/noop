import SwiftUI
import StrandDesign

/// nikhil/custom: the Today row under the hero scores, swapped from the Live Session (silent guardian)
/// start to the same sport picker → live workout flow as the Workouts screen's `WorkoutStartControl`.
/// Keeps the row's translucent chrome so it still reads as part of the sky scene. An isolated leaf:
/// it observes `AppModel` (which publishes ~1 Hz while live) so ticks re-render only this row, not Today.
struct TodayWorkoutStartRow: View {
    @EnvironmentObject var model: AppModel
    let cardOpacity: Double
    @State private var showLiveWorkout = false
    @State private var showStartSport = false

    var body: some View {
        #if os(iOS)
        // Half and half: a workout on the left, the Lift Log on the right.
        HStack(spacing: 10) {
            workoutButton
            TodayLiftStartButton(cardOpacity: cardOpacity)
        }
        #else
        // The Lift Log session lives at the iOS app root only, so the Mac keeps the full-width row.
        workoutButton
        #endif
    }

    private var workoutButton: some View {
        let active = model.activeWorkout != nil
        return Button {
            if active { showLiveWorkout = true } else { showStartSport = true }
        } label: {
            TodayStartLabel(icon: active ? "timer" : "figure.run",
                            title: active ? "View workout" : "Start workout",
                            cardOpacity: cardOpacity)
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel(active ? "View the active workout" : "Start a workout")
        .sheet(isPresented: $showLiveWorkout) {
            LiveWorkoutView(onClose: { showLiveWorkout = false })
                .environmentObject(model.live)
        }
        .workoutSelectionCover(isPresented: $showStartSport) {
            StartWorkoutSheet(onStartWorkout: { name, plan in
                model.startWorkout(sport: name, intervals: plan)
                showLiveWorkout = true
            })
        }
    }
}

#if os(iOS)
/// nikhil/custom: the right half of the row. Opens the Lift Log to pick a program, or, while a lift
/// session is running, brings that session back up (the same sheet the session bar opens).
private struct TodayLiftStartButton: View {
    @EnvironmentObject private var liftSession: LiftSessionController
    let cardOpacity: Double

    var body: some View {
        if liftSession.isActive {
            Button { liftSession.isPresented = true } label: {
                TodayStartLabel(icon: "dumbbell.fill", title: "View lifting", cardOpacity: cardOpacity)
            }
            .buttonStyle(LiquidPressStyle())
            .accessibilityLabel("View the lift session")
        } else {
            NavigationLink { LiftLogView() } label: {
                TodayStartLabel(icon: "dumbbell.fill", title: "Start lifting", cardOpacity: cardOpacity)
            }
            .buttonStyle(LiquidPressStyle())
            .accessibilityLabel("Open the Lift Log to start lifting")
        }
    }
}
#endif

/// One half of the start row: icon, title and chevron on the translucent panel.
private struct TodayStartLabel: View {
    let icon: String
    let title: LocalizedStringKey
    let cardOpacity: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StrandPalette.metricCyan)
            Text(title)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background(NoopPanelSurface(cornerRadius: 18, surfaceOpacity: cardOpacity))
    }
}
