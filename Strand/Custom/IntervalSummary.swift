import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

// nikhil/custom — the after-workout read of an interval workout: per-block heart rate, time in the block's
// target zone, the heart-rate drop over the first minute of each rest, and the same figures for the last
// session of the same activity and plan. Built from the block log the live session saved (IntervalLogStore)
// and the workout's recorded HR. Shown by IntervalBreakdownCard and summarised for the coach.

struct IntervalSummary: Equatable {

    struct Block: Equatable, Identifiable {
        let index: Int
        let kind: IntervalBlockKind
        let round: Int
        let targetZone: Int
        let seconds: Int
        let skipped: Bool
        let avgHr: Int?
        let peakHr: Int?
        /// Seconds of the block spent in its target zone.
        let targetSeconds: Double
        /// Rest blocks: bpm fallen from the start of the rest to one minute in. Positive = it fell.
        let recoveryBpm: Int?
        var id: Int { index }
        var targetFraction: Double { seconds > 0 ? min(1, targetSeconds / Double(seconds)) : 0 }
    }

    let entry: IntervalLogStore.Entry
    let blocks: [Block]

    var workBlocks: [Block] { blocks.filter { $0.kind == .work } }

    /// Mean seconds in the target zone per work block.
    var avgWorkTargetSeconds: Double? {
        let w = workBlocks
        return w.isEmpty ? nil : w.map(\.targetSeconds).reduce(0, +) / Double(w.count)
    }

    var avgWorkHr: Int? { Self.mean(workBlocks.compactMap(\.avgHr)) }
    var avgRecoveryBpm: Int? { Self.mean(blocks.compactMap(\.recoveryBpm)) }

    // MARK: Build

    /// Gap credited to one sample, capped so a dropped link isn't counted as time in a zone.
    static let maxSampleGapSeconds = 5
    /// Window either side of a moment that the HR at that moment is averaged over.
    static let pointWindowSeconds = 5
    static let recoveryOffsetSeconds = 60

    static func build(entry: IntervalLogStore.Entry, samples: [HRSample], zones: HRZoneSet) -> IntervalSummary {
        let sorted = samples.sorted { $0.ts < $1.ts }
        var rounds = [Int](repeating: 0, count: 2)   // [work, rest] counters
        let blocks = entry.blocks.enumerated().map { i, b -> Block in
            let from = Int(b.start.timeIntervalSince1970), to = Int(b.end.timeIntervalSince1970)
            let inBlock = sorted.filter { $0.ts >= from && $0.ts < to }
            var target = 0.0
            for (j, s) in inBlock.enumerated() {
                let nextTs = j + 1 < inBlock.count ? inBlock[j + 1].ts : to
                let gap = Double(min(max(nextTs - s.ts, 0), maxSampleGapSeconds))
                if zones.zoneNumber(forBPM: Double(s.bpm)) == b.targetZone { target += gap }
            }
            var recovery: Int?
            if b.kind == .rest, to - from >= recoveryOffsetSeconds,
               let atStart = hr(at: from, in: sorted), let atMinute = hr(at: from + recoveryOffsetSeconds, in: sorted) {
                recovery = Int((atStart - atMinute).rounded())
            }
            let counter = b.kind == .work ? 0 : 1
            rounds[counter] += 1
            return Block(index: i, kind: b.kind, round: rounds[counter], targetZone: b.targetZone,
                         seconds: max(0, to - from), skipped: b.skipped,
                         avgHr: mean(inBlock.map(\.bpm)), peakHr: inBlock.map(\.bpm).max(),
                         targetSeconds: target, recoveryBpm: recovery)
        }
        return IntervalSummary(entry: entry, blocks: blocks)
    }

    /// Mean HR within `pointWindowSeconds` of `ts`, or nil with no sample there.
    static func hr(at ts: Int, in sorted: [HRSample]) -> Double? {
        let near = sorted.filter { abs($0.ts - ts) <= pointWindowSeconds }.map(\.bpm)
        return near.isEmpty ? nil : Double(near.reduce(0, +)) / Double(near.count)
    }

    static func mean(_ xs: [Int]) -> Int? {
        xs.isEmpty ? nil : Int((Double(xs.reduce(0, +)) / Double(xs.count)).rounded())
    }

    // MARK: Matching

    /// Same activity and the same timing and zones (rounds may differ: a shorter session still compares rep for rep).
    static func sameSession(_ a: IntervalPlan, _ b: IntervalPlan) -> Bool {
        a.workSeconds == b.workSeconds && a.restSeconds == b.restSeconds
            && a.workZone == b.workZone && a.restZone == b.restZone && a.restFirst == b.restFirst
    }

    /// The most recent earlier entry of the same activity and plan.
    static func previous(to entry: IntervalLogStore.Entry, in all: [IntervalLogStore.Entry]) -> IntervalLogStore.Entry? {
        all.filter { $0.startSec < entry.startSec && $0.sport == entry.sport && sameSession($0.plan, entry.plan) }
            .max { $0.startSec < $1.startSec }
    }

    // MARK: Loading

    struct Loaded: Equatable {
        let current: IntervalSummary
        let previous: IntervalSummary?
        let previousStart: Date?
    }

    @MainActor
    static func load(startTs: Int, sport: String, repo: Repository, zones: HRZoneSet,
                     entries: [IntervalLogStore.Entry] = IntervalLogStore.entries()) async -> Loaded? {
        guard let entry = entries.first(where: { $0.startSec == startTs && $0.sport == sport }) else { return nil }
        let current = await summary(of: entry, repo: repo, zones: zones)
        var previous: IntervalSummary?
        if let prev = Self.previous(to: entry, in: entries) {
            previous = await summary(of: prev, repo: repo, zones: zones)
        }
        return Loaded(current: current, previous: previous,
                      previousStart: previous.map { Date(timeIntervalSince1970: TimeInterval($0.entry.startSec)) })
    }

    @MainActor
    private static func summary(of entry: IntervalLogStore.Entry, repo: Repository, zones: HRZoneSet) async -> IntervalSummary {
        let from = Int(entry.blocks.first?.start.timeIntervalSince1970 ?? TimeInterval(entry.startSec))
        let to = Int(entry.blocks.last?.end.timeIntervalSince1970 ?? TimeInterval(entry.startSec))
        let samples = await repo.hrSamples(from: from - pointWindowSeconds,
                                           to: to + recoveryOffsetSeconds + pointWindowSeconds)
        return build(entry: entry, samples: samples, zones: zones)
    }

    // MARK: Coach

    /// One line for the coach's recent-workouts block.
    static func coachLine(_ l: Loaded) -> String {
        let c = l.current
        var parts = ["intervals \(c.entry.plan.summary), \(c.workBlocks.count) work blocks done"]
        func vs(_ now: String, _ last: String?) -> String { last.map { "\(now) (last same session: \($0))" } ?? now }
        let z = c.entry.plan.workZone
        if let t = c.avgWorkTargetSeconds {
            parts.append(vs("avg \(IntervalPreset.clock(Int(t.rounded()))) per work block in Z\(z)",
                            l.previous?.avgWorkTargetSeconds.map { IntervalPreset.clock(Int($0.rounded())) }))
        }
        if let hr = c.avgWorkHr { parts.append(vs("avg work HR \(hr)", l.previous?.avgWorkHr.map(String.init))) }
        if let r = c.avgRecoveryBpm {
            parts.append(vs("HR fell avg \(r) bpm in the first minute of rest",
                            l.previous?.avgRecoveryBpm.map(String.init)))
        }
        return parts.joined(separator: "; ")
    }
}
