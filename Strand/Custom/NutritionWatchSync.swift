import Foundation
import StrandDesign

// nikhil/custom — sends the day's food balance to the watch's nutrition complication. Runs after a food
// edit, a plan change, a refresh (new active energy) and a foreground, debounced like `HydrationSync`.
// The bridge decides whether a change is worth a complication transfer.
@MainActor
enum NutritionWatchSync {
    /// Sends the snapshot to the watch (set by the iOS app; nil on macOS).
    static var pushToWatch: ((WatchNutritionSnapshot) -> Void)?
    private static var pending: Task<Void, Never>?

    static func changed(_ repo: Repository) {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await run(repo)
        }
    }

    static func run(_ repo: Repository) async {
        guard let push = pushToWatch, UserDefaults.standard.bool(forKey: NutritionPrefs.enabledKey),
              let snap = await NutritionTodayCard.load(repo), snap.hasStandard else { return }
        push(watchSnapshot(snap.balance))
    }

    static func watchSnapshot(_ b: NutritionBalance, now: Date = Date()) -> WatchNutritionSnapshot {
        let eq = b.equation
        return WatchNutritionSnapshot(day: Repository.localDayKey(now), offPlanKcal: eq.total,
                                      targetKcal: Int(b.targetBalance.rounded()),
                                      inKcal: eq.inKcal, outKcal: eq.outKcal, asOf: now)
    }
}
