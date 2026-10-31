import Foundation
import WhoopStore

// nikhil/custom — launch-time repair for a strap registered twice (see
// `DeviceRegistryStore.mergeArchivedDuplicatesOfActiveStrap`). Moves the archived row's raw recordings onto
// the active strap, then rescores the whole history so the nights it held get their sleep and scores. A
// single registry read on every later launch: once merged there is nothing left to match.

extension AppModel {
    /// One-shot guard for `restoreCanonicalHistoryAfterFullMerge` (undoing the first merge build's moves).
    static let duplicateStrapRestoreFlagKey = "custom.duplicateStrapMerge.restoreCanonical.v1.done"

    func mergeDuplicateStrapIfNeeded() async {
        guard let store = await repo.storeHandle() else { return }
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        var changed = false
        do {
            if !UserDefaults.standard.bool(forKey: Self.duplicateStrapRestoreFlagKey) {
                if try registry.restoreCanonicalHistoryAfterFullMerge() {
                    intelligence.diagnosticSink?("Duplicate strap merge: moved imported and computed history back under my-whoop.", nil)
                    changed = true
                }
                UserDefaults.standard.set(true, forKey: Self.duplicateStrapRestoreFlagKey)
            }
            let merged = try registry.mergeArchivedDuplicatesOfActiveStrap()
            if !merged.isEmpty {
                let pairs = merged.map { "\($0.fromId) → \($0.toId)" }.joined(separator: ", ")
                intelligence.diagnosticSink?("Duplicate strap merge: moved raw recordings \(pairs).", nil)
                changed = true
            }
        } catch {
            intelligence.diagnosticSink?("Duplicate strap merge FAILED, nothing changed (one transaction): \(error)", nil)
            return
        }
        guard changed else { return }
        await intelligence.analyzeRecent(maxDays: 4000, triggerLabel: "duplicate-strap-merge",
                                         preserveUnscoredHistory: true)
    }
}
