import Foundation

// nikhil/custom — drives the interval clock (IntervalWorkout.swift) of an interval-mode workout: a 1 Hz timer
// while the app runs, plus a tick on every strap HR packet (`ingestHR`) so the cues keep coming while the
// phone is locked and the timer is not firing. Every transition buzzes the strap behind the Interval timer's
// haptic toggle; the session is snapshotted on each change so a relaunch resumes on the right block.
extension AppModel {

    func startIntervals(_ plan: IntervalPlan, at start: Date) {
        guard var w = activeWorkout else { return }
        let session = IntervalSession(plan: plan, start: start)
        w.intervals = session
        activeWorkout = w
        IntervalSessionStore.store(session)
        fireIntervalCue(session.openingCue)
        startIntervalTicker()
    }

    func rehydrateIntervals() {
        guard var w = activeWorkout, w.intervals == nil, let session = IntervalSessionStore.load() else { return }
        w.intervals = session
        activeWorkout = w
        startIntervalTicker()
        tickIntervals()
    }

    func tickIntervals(at now: Date = Date()) {
        guard var w = activeWorkout, var session = w.intervals else { return }
        guard let cue = session.tick(at: now) else { return }
        w.intervals = session
        activeWorkout = w
        IntervalSessionStore.store(session)
        fireIntervalCue(cue)
    }

    func skipInterval() {
        guard var w = activeWorkout, var session = w.intervals, let cue = session.skip(at: Date()) else { return }
        w.intervals = session
        activeWorkout = w
        IntervalSessionStore.store(session)
        fireIntervalCue(cue)
    }

    func toggleIntervalPause() {
        guard var w = activeWorkout, var session = w.intervals else { return }
        if session.isPaused { session.resume(at: Date()) } else { session.pause(at: Date()) }
        w.intervals = session
        activeWorkout = w
        IntervalSessionStore.store(session)
    }

    /// Pausing the workout pauses the intervals too, and resuming it resumes them.
    func syncIntervalsToWorkoutPause() {
        guard var w = activeWorkout, var session = w.intervals else { return }
        if w.isPaused { session.pause(at: Date()) } else { session.resume(at: Date()) }
        w.intervals = session
        activeWorkout = w
        IntervalSessionStore.store(session)
    }

    /// Stop the clock. `saving` is the ending workout whose block log is kept for the breakdown (nil = discard).
    func stopIntervals(saving workout: ActiveWorkout?) {
        intervalTicker?.invalidate()
        intervalTicker = nil
        IntervalSessionStore.store(nil)
        guard let workout, var session = workout.intervals else { return }
        // Close the block in progress so the log covers the whole interval part of the session.
        if !session.finished { _ = session.skip(at: Date()) }
        let blocks = session.log
        guard !blocks.isEmpty else { return }
        IntervalLogStore.save(IntervalLogStore.Entry(startSec: Int(workout.start.timeIntervalSince1970),
                                                     sport: workout.sport, plan: session.plan, blocks: blocks))
    }

    private func startIntervalTicker() {
        intervalTicker?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickIntervals() }
        }
        RunLoop.main.add(timer, forMode: .common)
        intervalTicker = timer
    }

    private func fireIntervalCue(_ cue: IntervalSession.Cue) {
        buzz(loops: IntervalSession.loops(for: cue), gate: HapticPrefs.intervals)
    }
}
