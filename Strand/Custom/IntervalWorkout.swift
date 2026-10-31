import Foundation

// nikhil/custom — interval mode for a recorded workout. Pure values and stores, no UI and no BLE: the plan the
// setup screen builds, the clock that walks its blocks, the strap cue each transition earns, and the on-pace
// zone targets the live bars draw. AppModel+Intervals drives it from the live workout.
//
// Cues (one meaning per count): 3 buzzes = go work, 1 buzz = go rest, 1 buzz 10 s before a work block (it only
// ever comes DURING rest, where "go rest" never does), 5 buzzes = the planned rounds are done, cooldown.

enum IntervalBlockKind: String, Codable, Equatable {
    case work, rest
}

struct IntervalPlan: Codable, Equatable {
    var workSeconds = 240
    var restSeconds = 180
    /// nil = keep cycling until the workout ends.
    var rounds: Int? = 6
    var restFirst = false
    var workZone = 3
    var restZone = 2

    /// Blocks in the plan: N work blocks with a rest between each (and a leading rest when rest-first), so the
    /// last block is always work. nil when open-ended.
    var blockCount: Int? { rounds.map { restFirst ? 2 * $0 : 2 * $0 - 1 } }

    func kind(ofBlock i: Int) -> IntervalBlockKind { (i % 2 == 0) != restFirst ? .work : .rest }
    func duration(ofBlock i: Int) -> Int { max(1, kind(ofBlock: i) == .work ? workSeconds : restSeconds) }
    func zone(ofBlock i: Int) -> Int { kind(ofBlock: i) == .work ? workZone : restZone }
    /// 1-based round a block belongs to: a work block and the rest leading into (rest-first) or out of it.
    func round(ofBlock i: Int) -> Int { i / 2 + 1 }

    var totalSeconds: Int? {
        blockCount.map { n in (0..<n).reduce(0) { $0 + duration(ofBlock: $1) } }
    }

    /// "6 × 4:00 Z3 / 3:00 Z2", rest-first as "rest 3:00 Z2 → 4:00 Z3", "∞" when open-ended.
    var summary: String {
        let count = rounds.map { "\($0) ×" } ?? "∞ ×"
        let work = "\(IntervalPreset.clock(workSeconds)) Z\(workZone)"
        let rest = "\(IntervalPreset.clock(restSeconds)) Z\(restZone)"
        return restFirst ? "\(count) rest \(rest) → \(work)" : "\(count) \(work) / \(rest)"
    }

    /// A one-tap preset's timing, keeping this plan's zones.
    func applying(_ preset: IntervalPreset) -> IntervalPlan {
        var p = self
        p.workSeconds = preset.workSeconds
        p.restSeconds = preset.restSeconds
        p.rounds = preset.rounds
        p.restFirst = preset.restFirst
        return p
    }

    func matches(_ preset: IntervalPreset) -> Bool {
        workSeconds == preset.workSeconds && restSeconds == preset.restSeconds
            && rounds == preset.rounds && restFirst == preset.restFirst
    }

    static func clamped(zone: Int) -> Int { min(max(zone, 1), 5) }
}

/// The running interval clock. Wall-clock based, so it survives the app sleeping between strap packets: a tick
/// that arrives late catches up across every block that ended meanwhile and cues only the newest transition.
struct IntervalSession: Codable, Equatable {

    enum Cue: String, Codable, Equatable { case work, rest, headsUp, done }

    /// A finished block, in wall-clock time (pauses included), for the after-workout breakdown.
    struct LoggedBlock: Codable, Equatable {
        let kind: IntervalBlockKind
        let targetZone: Int
        let start: Date
        let end: Date
        let skipped: Bool
    }

    static let headsUpSeconds = 10

    let plan: IntervalPlan
    private(set) var blockIndex = 0
    /// When the current block started, pushed forward by every pause so `now - blockStart` is active time.
    private(set) var blockStart: Date
    /// When the current block really started, for the log.
    private(set) var blockWallStart: Date
    private(set) var pausedAt: Date?
    /// The planned rounds are done; the workout records on as cooldown.
    private(set) var finished = false
    private(set) var finishedAt: Date?
    private var headsUpFired = false
    private(set) var log: [LoggedBlock] = []
    /// Bumped on every cue so a view can fire a phone haptic per cue, with the cue that fired.
    private(set) var cueCount = 0
    private(set) var lastCue: Cue?

    init(plan: IntervalPlan, start: Date) {
        self.plan = plan
        blockStart = start
        blockWallStart = start
    }

    var isPaused: Bool { pausedAt != nil }
    var kind: IntervalBlockKind { plan.kind(ofBlock: blockIndex) }
    var targetZone: Int { plan.zone(ofBlock: blockIndex) }
    var round: Int { plan.round(ofBlock: blockIndex) }
    var blockDuration: Int { plan.duration(ofBlock: blockIndex) }
    private var isLastBlock: Bool { plan.blockCount.map { blockIndex + 1 >= $0 } ?? false }

    func activeElapsed(at now: Date) -> TimeInterval {
        max(0, (pausedAt ?? now).timeIntervalSince(blockStart))
    }

    func remaining(at now: Date) -> Int {
        max(0, Int((Double(blockDuration) - activeElapsed(at: now)).rounded(.up)))
    }

    func progress(at now: Date) -> Double {
        finished ? 1 : min(1, activeElapsed(at: now) / Double(blockDuration))
    }

    /// The block after this one, or nil on the last.
    var next: (kind: IntervalBlockKind, seconds: Int, zone: Int)? {
        guard !isLastBlock else { return nil }
        let i = blockIndex + 1
        return (plan.kind(ofBlock: i), plan.duration(ofBlock: i), plan.zone(ofBlock: i))
    }

    /// The cue the first block opens with ("go work" or "go rest").
    var openingCue: Cue { kind == .work ? .work : .rest }

    /// Advance the clock to `now`. Returns the cue to fire, if any.
    mutating func tick(at now: Date) -> Cue? {
        guard !finished, pausedAt == nil else { return nil }
        var cue: Cue?
        while !finished, activeElapsed(at: now) >= Double(blockDuration) {
            let end = blockStart.addingTimeInterval(Double(blockDuration))
            cue = advance(endingAt: end, skipped: false)
        }
        if !finished, kind == .rest, !headsUpFired, next?.kind == .work,
           blockDuration > 2 * Self.headsUpSeconds, remaining(at: now) <= Self.headsUpSeconds {
            headsUpFired = true
            cue = cue ?? .headsUp
        }
        if let cue { record(cue) }
        return cue
    }

    /// Jump to the next block now. Returns its cue.
    mutating func skip(at now: Date) -> Cue? {
        guard !finished else { return nil }
        let wasPaused = pausedAt != nil
        // Close the block at the active time it actually ran, then restart the clock at `now`.
        let cue = advance(endingAt: blockStart.addingTimeInterval(activeElapsed(at: now)), skipped: true,
                          wallEnd: now)
        blockStart = now
        blockWallStart = now
        pausedAt = wasPaused && !finished ? now : nil
        record(cue)
        return cue
    }

    mutating func pause(at now: Date) {
        guard pausedAt == nil, !finished else { return }
        pausedAt = now
    }

    mutating func resume(at now: Date) {
        guard let p = pausedAt else { return }
        blockStart = blockStart.addingTimeInterval(now.timeIntervalSince(p))
        pausedAt = nil
    }

    /// Close the current block, then start the next one at `end` (or finish).
    private mutating func advance(endingAt end: Date, skipped: Bool, wallEnd: Date? = nil) -> Cue {
        let logEnd = wallEnd ?? blockWallStart.addingTimeInterval(end.timeIntervalSince(blockStart))
        log.append(LoggedBlock(kind: kind, targetZone: targetZone, start: blockWallStart, end: logEnd,
                               skipped: skipped))
        if isLastBlock {
            finished = true
            finishedAt = logEnd
            pausedAt = nil
            return .done
        }
        blockIndex += 1
        blockStart = end
        blockWallStart = logEnd
        headsUpFired = false
        return kind == .work ? .work : .rest
    }

    private mutating func record(_ cue: Cue) {
        lastCue = cue
        cueCount += 1
    }

    /// Strap buzzes for a cue. The heads-up is the strap's single short buzz; it can't be lighter than "go rest"
    /// (both are one pulse of the confirmed pattern) — the phase it lands in is what tells them apart.
    static func loops(for cue: Cue) -> UInt8 {
        switch cue {
        case .work: return 3
        case .rest, .headsUp: return 1
        case .done: return 5
        }
    }

    // MARK: On-pace zone targets

    /// The first part of every block that counts toward no target: the heart rate is still climbing (or
    /// falling) into the block's zone. A minute, or half a block shorter than two minutes.
    static func lagAllowance(blockSeconds: Int) -> Double { min(60, Double(blockSeconds) / 2) }

    /// Minutes the plan expects in zones 1…5 (index 0 = Z1) by `now`: each block run so far credits its
    /// target zone with its active time past the lag allowance. Stops growing once the rounds are done.
    func paceTargets(at now: Date) -> [Double] {
        var out = [Double](repeating: 0, count: 5)
        func credit(zone: Int, seconds: Double, blockSeconds: Int) {
            let counted = max(0, seconds - Self.lagAllowance(blockSeconds: blockSeconds))
            out[IntervalPlan.clamped(zone: zone) - 1] += counted / 60
        }
        for (i, b) in log.enumerated() {
            // A logged block's active time: its planned length unless it was skipped short.
            let planned = plan.duration(ofBlock: i)
            let ran = b.skipped ? min(Double(planned), b.end.timeIntervalSince(b.start)) : Double(planned)
            credit(zone: b.targetZone, seconds: ran, blockSeconds: planned)
        }
        if !finished {
            credit(zone: targetZone, seconds: min(activeElapsed(at: now), Double(blockDuration)),
                   blockSeconds: blockDuration)
        }
        return out
    }
}

// MARK: - Stores

/// Per-activity interval memory: which activities open the setup screen, and each one's last plan.
enum IntervalWorkoutPrefs {
    static let enabledKey = "custom.intervalWorkout.enabledSports"
    static let plansKey = "custom.intervalWorkout.plans"

    static func isEnabled(sport: String, _ d: UserDefaults = .standard) -> Bool {
        (d.stringArray(forKey: enabledKey) ?? []).contains(sport)
    }

    static func setEnabled(_ on: Bool, sport: String, _ d: UserDefaults = .standard) {
        var set = Set(d.stringArray(forKey: enabledKey) ?? [])
        if on { set.insert(sport) } else { set.remove(sport) }
        d.set(set.sorted(), forKey: enabledKey)
    }

    static func plan(sport: String, _ d: UserDefaults = .standard) -> IntervalPlan {
        allPlans(d)[sport] ?? IntervalPlan()
    }

    static func save(_ plan: IntervalPlan, sport: String, _ d: UserDefaults = .standard) {
        var all = allPlans(d)
        all[sport] = plan
        if let data = try? JSONEncoder().encode(all) { d.set(data, forKey: plansKey) }
    }

    private static func allPlans(_ d: UserDefaults) -> [String: IntervalPlan] {
        guard let data = d.data(forKey: plansKey),
              let all = try? JSONDecoder().decode([String: IntervalPlan].self, from: data) else { return [:] }
        return all
    }
}

/// The in-flight session, so an app relaunch mid-workout resumes on the right block. Cleared with the workout.
enum IntervalSessionStore {
    static let key = "custom.intervalWorkout.active"

    static func store(_ s: IntervalSession?, _ d: UserDefaults = .standard) {
        guard let s, let data = try? JSONEncoder().encode(s) else { d.removeObject(forKey: key); return }
        d.set(data, forKey: key)
    }

    static func load(_ d: UserDefaults = .standard) -> IntervalSession? {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(IntervalSession.self, from: $0) }
    }
}

/// Each finished interval workout's plan and block log, keyed by the workout's start second, for the
/// after-workout breakdown.
enum IntervalLogStore {
    static let key = "custom.intervalWorkout.logs"

    struct Entry: Codable, Equatable {
        let startSec: Int
        let sport: String
        let plan: IntervalPlan
        let blocks: [IntervalSession.LoggedBlock]
    }

    static func save(_ e: Entry, _ d: UserDefaults = .standard) {
        var all = entries(d).filter { $0.startSec != e.startSec }
        all.append(e)
        if let data = try? JSONEncoder().encode(all) { d.set(data, forKey: key) }
    }

    static func entries(_ d: UserDefaults = .standard) -> [Entry] {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }
}
