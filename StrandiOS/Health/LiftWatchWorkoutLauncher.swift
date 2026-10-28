import Foundation
import Combine
import HealthKit
import WatchConnectivity

// nikhil/custom — a new Lift Log session launches a strength-training workout in the NOOP Watch app
// (watch sensors → Apple Health + Activity rings), and the session's end ends it. The strap keeps feeding
// the Lift Log itself; HealthKitBridge.writeWorkouts skips the strap's copy of a session the Watch recorded.
//
// It also drives the watch's Lift Log screen: every change to the session is pushed to the watch as a
// `LiftWatchState`, and the watch's button comes back as a `LiftWatchAction` (WatchSessionBridge routes it).
@MainActor
enum LiftWatchWorkoutLauncher {
    private static let store = HKHealthStore()
    private static weak var controller: LiftSessionController?
    private static var cancellables = Set<AnyCancellable>()
    private static var lastSent: LiftWatchState??

    static func install(controller: LiftSessionController, log: @escaping (String) -> Void) {
        self.controller = controller
        LiftSessionController.onSessionStarted = { start(log: log) }
        LiftSessionController.onSessionEnded = { saved in end(saved: saved, log: log) }
        WatchSessionBridge.onLiftAction = { action in
            controller.applyWatchAction(LiftSlot(exerciseIndex: action.exerciseIndex, setIndex: action.setIndex),
                                        weightKg: action.weightKg, reps: action.reps)
        }
        WatchSessionBridge.liftStateProvider = { currentStatePayload() }
        // Push on every session change (engine, typed numbers, last-session greys), coalesced.
        controller.objectWillChange
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { _ in pushState() }
            .store(in: &cancellables)
    }

    private static var imperial: Bool {
        UserDefaults.standard.string(forKey: UnitPrefs.systemKey) == UnitSystem.imperial.rawValue
    }

    static func currentStatePayload() -> [String: Any] {
        [LiftWatchState.messageKey: controller?.watchState(imperial: imperial)?.encoded() ?? LiftWatchState.noSession]
    }

    private static func pushState() {
        let state = controller?.watchState(imperial: imperial)
        if let lastSent, lastSent == state { return }
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isPaired,
              session.isWatchAppInstalled, session.isReachable else { return }
        lastSent = .some(state)
        session.sendMessage(currentStatePayload(), replyHandler: nil) { _ in lastSent = nil }
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
