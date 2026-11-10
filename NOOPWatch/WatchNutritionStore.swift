import Foundation
import StrandDesign
import WidgetKit

// nikhil/custom — the watch side of the food balance: the phone pushes `WatchNutritionSnapshot` (context,
// message or complication transfer); this saves it to the App Group and reloads the nutrition
// complication, which reads it from there. Nothing on the watch edits food.
final class WatchNutritionStore {
    static let shared = WatchNutritionStore()
    static let complicationKind = "NOOPNutritionComplication"

    func receive(_ payload: [String: Any]) {
        guard let snap = WatchNutritionSnapshot.decode(payload[WatchNutritionSnapshot.contextKey] as? Data),
              snap != WatchNutritionSnapshot.load() else { return }
        snap.save()
        WidgetCenter.shared.reloadTimelines(ofKind: Self.complicationKind)
    }
}
