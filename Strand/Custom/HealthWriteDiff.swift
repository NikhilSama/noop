import Foundation

// nikhil/custom — battery: the Apple Health write-back used to delete and rewrite its whole window on
// every pass (48 h of 1-minute HR, 14 days of sleep, workouts and vitals), every ~15 minutes. Each
// write fans out to the Health daemon's indexing and iCloud sync, which is what showed up as "Health"
// in iOS Battery. These pure helpers let each writer fingerprint what it is about to write, compare it
// with what the last SUCCESSFUL pass wrote, and touch only the records that changed.
//
// Fingerprints are local-only (UserDefaults on this phone), so FNV-1a is used purely for stability
// across launches, not for any cross-platform contract.
enum HealthWriteDiff {

    static func fnv1a(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return String(h, radix: 16)
    }

    /// Keys whose new fingerprint differs from the stored one (new keys included), sorted.
    static func changedKeys(current: [String: String], previous: [String: String]) -> [String] {
        current.filter { previous[$0.key] != $0.value }.map(\.key).sorted()
    }

    /// The hour (epoch seconds, UTC-aligned) a bucket falls in.
    static func hourStart(_ ts: Int) -> Int { ts - ((ts % 3600) + 3600) % 3600 }

    /// Per-hour fingerprints of 1-minute HR buckets.
    static func hourFingerprints(_ buckets: [(ts: Int, bpm: Double)]) -> [Int: String] {
        var text: [Int: String] = [:]
        for b in buckets.sorted(by: { $0.ts < $1.ts }) {
            text[hourStart(b.ts), default: ""] += "\(b.ts):\(String(format: "%.3f", b.bpm));"
        }
        return text.mapValues(fnv1a)
    }

    /// Hours to delete-and-rewrite: hours whose content changed, plus previously written hours inside
    /// the window that no longer have any buckets (so a vanished hour is cleared, not left stale).
    static func changedHours(current: [Int: String], previous: [Int: String], windowStart: Int) -> [Int] {
        var hours = Set(current.filter { previous[$0.key] != $0.value }.map(\.key))
        for h in previous.keys where h >= hourStart(windowStart) && current[h] == nil { hours.insert(h) }
        return hours.sorted()
    }

    /// Collapse sorted hour starts into contiguous [start, end) ranges, so a first run (every hour
    /// changed) issues one delete instead of 48.
    static func ranges(ofHours hours: [Int]) -> [(start: Int, end: Int)] {
        var out: [(start: Int, end: Int)] = []
        for h in hours.sorted() {
            if let last = out.last, last.end == h {
                out[out.count - 1].end = h + 3600
            } else {
                out.append((h, h + 3600))
            }
        }
        return out
    }

    // MARK: - Stored fingerprints

    static func load(_ name: String, defaults: UserDefaults = .standard) -> [String: String] {
        defaults.dictionary(forKey: key(name)) as? [String: String] ?? [:]
    }

    static func save(_ fingerprints: [String: String], _ name: String, defaults: UserDefaults = .standard) {
        defaults.set(fingerprints, forKey: key(name))
    }

    private static func key(_ name: String) -> String { "custom.hkWriteFingerprints.v1.\(name)" }
}
