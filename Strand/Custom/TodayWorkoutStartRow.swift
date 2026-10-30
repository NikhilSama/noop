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
        let active = model.activeWorkout != nil
        Button {
            if active { showLiveWorkout = true } else { showStartSport = true }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: active ? "timer" : "figure.run")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StrandPalette.metricCyan)
                Text(active ? "View active workout" : "Start workout")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(NoopPanelSurface(cornerRadius: 18, surfaceOpacity: cardOpacity))
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel(active ? "View the active workout" : "Start a workout")
        .sheet(isPresented: $showLiveWorkout) {
            LiveWorkoutView(onClose: { showLiveWorkout = false })
                .environmentObject(model.live)
        }
        .workoutSelectionCover(isPresented: $showStartSport) {
            StartWorkoutSheet { name in
                model.startWorkout(sport: name)
                showLiveWorkout = true
            }
        }
    }
}
