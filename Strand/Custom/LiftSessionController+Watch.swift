import Foundation

// nikhil/custom — what the watch's Lift Log screen is told about the running session.
extension LiftSessionController {
    /// The set the watch should focus on: the one being worked, else the one the big button starts next.
    func watchFocusSlot() -> LiftSlot? {
        guard let engine else { return nil }
        switch engine.stage {
        case .working(let slot): return slot
        case .resting: return engine.upcomingSlot
        case .warmup: return engine.nextPendingSlot
        case .finished: return nil
        }
    }

    func watchState(imperial: Bool) -> LiftWatchState? {
        guard let engine else { return nil }
        let stage: LiftWatchState.Stage
        var restEndsAt: Int?
        switch engine.stage {
        case .warmup: stage = .warmup
        case .working: stage = .working
        case .resting(_, let endsAt): stage = .resting; restEndsAt = endsAt
        case .finished: stage = .finished
        }
        let slot = watchFocusSlot()
        let item = slot.flatMap { engine.planItem(for: $0) }
        let grey = slot.map { values(of: $0) } ?? .none
        let typed = slot.flatMap { pendingValues[$0] }
        return LiftWatchState(
            stage: slot == nil && stage != .finished ? .finished : stage,
            exercise: item?.exercise ?? "All sets done",
            exerciseIndex: slot?.exerciseIndex ?? 0,
            exerciseCount: engine.plan.count,
            setIndex: slot?.setIndex ?? 0,
            setCount: item?.targetSets ?? 0,
            weightKg: typed?.weightKg ?? grey.weightKg,
            reps: typed?.reps ?? grey.reps,
            restEndsAt: restEndsAt,
            completedSets: engine.completedWorkingSets,
            plannedSets: engine.plannedWorkingSets,
            imperial: imperial)
    }
}
