import Foundation
import HealthKit
import WatchConnectivity

// nikhil/custom — a new Lift Log session launches a strength-training workout in the NOOP Watch app
// (watch sensors → Apple Health + Activity rings), and the session's end ends it. The strap keeps feeding
// the Lift Log itself; HealthKitBridge.writeWorkouts skips the strap's copy of a session the Watch recorded.
@MainActor
enum LiftWatchWorkoutLauncher {
    private static let store = HKHealthStore()

    static func install(log: @escaping (String) -> Void) {
        LiftSessionController.onSessionStarted = { start(log: log) }
        LiftSessionController.onSessionEnded = { saved in end(saved: saved, log: log) }
    }

    private static func start(log: @escaping (String) -> Void) {
        guard HKHealthStore.isHealthDataAvailable(), WCSession.isSupported(), WCSession.default.isPaired,
              WCSession.default.isWatchAppInstalled else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining
        config.locationType = .indoor
        store.startWatchApp(with: config) { ok, error in
            let line = ok ? "Lift Log: started the Watch strength workout"
                          : "Lift Log: could not start the Watch workout (\(error?.localizedDescription ?? "unknown"))"
            Task { @MainActor in log(line) }
        }
    }

    private static func end(saved: Bool, log: @escaping (String) -> Void) {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isPaired,
              session.isWatchAppInstalled else { return }
        let payload: [String: Any] = [LiftWatchWorkout.endMessageKey: saved,
                                      LiftWatchWorkout.sentAtKey: Date().timeIntervalSince1970]
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { _ in session.transferUserInfo(payload) }
        } else {
            session.transferUserInfo(payload)
        }
        log("Lift Log: asked the Watch to \(saved ? "save" : "discard") its workout")
    }
}
