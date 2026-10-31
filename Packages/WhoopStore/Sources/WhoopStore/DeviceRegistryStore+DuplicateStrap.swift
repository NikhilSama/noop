import Foundation
import GRDB

// nikhil/custom — repair for a strap registered twice.
//
// Re-adding a strap through the Add-device wizard archives its old registry row but leaves that row's
// `peripheralId`, so the same physical strap sits under two rows. Before `SourceIdentity.resolve` ranked
// matches by status, every link was attributed to the FIRST match, the archived row, and its samples were
// stored under an id the sleep detector does not read raw data from: a whole night with no sleep. This
// moves such a row's RAW strap recordings onto the active row, as though the link had been attributed
// correctly all along.
//
// Only the raw streams move. Imported history and the engine's computed scores deliberately live under the
// canonical `my-whoop` / `my-whoop-noop` ids forever (Repository reads them in union with the active
// strap), so moving those would split the canonical history and let stale computed rows shadow fresh ones.

extension DeviceRegistryStore {

    /// One merged pair: the archived row's id and the active row it was folded into.
    public struct DuplicateStrapMerge: Equatable, Sendable {
        public let fromId: String
        public let toId: String
    }

    /// Fold every archived WHOOP row that carries the ACTIVE WHOOP row's peripheral into the active row.
    ///
    /// For each such row, in one all-or-nothing transaction: its raw strap recordings (`rawStreamTables`)
    /// move onto the active id, the active row winning any primary-key clash; and its `peripheralId` is
    /// cleared, so no later link can resolve to it. Imported, computed and user-entered rows stay where they
    /// are (see the file comment). The registry row itself stays, archived, so nothing that remembers its
    /// id breaks.
    ///
    /// Idempotent: once merged, the archived row no longer carries the peripheral, so a second call finds
    /// nothing. Returns the pairs merged; empty on a clean registry (the common case, one read).
    @discardableResult
    public func mergeArchivedDuplicatesOfActiveStrap() throws -> [DuplicateStrapMerge] {
        try dbQueue.write { db in
            // Only the four columns this needs, read directly (the registry's row decoder is private to it).
            struct Entry { let id: String; let brand: String; let status: String; let peripheralId: String? }
            let rows = try Row.fetchAll(db, sql: "SELECT id, brand, status, peripheralId FROM pairedDevice").map {
                Entry(id: $0["id"], brand: $0["brand"] ?? "", status: $0["status"] ?? "", peripheralId: $0["peripheralId"])
            }
            // The same WHOOP test as `SourceIdentity.isWhoop`: the seeded legacy row, or a WHOOP brand.
            func isWhoop(_ e: Entry) -> Bool {
                e.id == "my-whoop" || e.brand.caseInsensitiveCompare("WHOOP") == .orderedSame
            }
            guard let active = rows.first(where: { $0.status == DeviceStatus.active.rawValue && isWhoop($0) }),
                  let peripheral = active.peripheralId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !peripheral.isEmpty else { return [] }
            let duplicates = rows.filter {
                $0.id != active.id && $0.status == DeviceStatus.archived.rawValue && isWhoop($0)
                    && $0.peripheralId?.caseInsensitiveCompare(peripheral) == .orderedSame
            }
            var merged: [DuplicateStrapMerge] = []
            for dup in duplicates {
                for table in Self.rawStreamTables {
                    try db.execute(sql: "UPDATE OR IGNORE \(table) SET deviceId = ? WHERE deviceId = ?",
                                   arguments: [active.id, dup.id])
                    try db.execute(sql: "DELETE FROM \(table) WHERE deviceId = ?", arguments: [dup.id])
                }
                try db.execute(sql: "UPDATE pairedDevice SET peripheralId = NULL WHERE id = ?", arguments: [dup.id])
                merged.append(DuplicateStrapMerge(fromId: dup.id, toId: active.id))
            }
            return merged
        }
    }

    /// The raw per-second strap streams: what a live link writes and the sleep detector reads from the
    /// active strap. Everything else in `deviceScopedTables` is imported, computed or user-entered.
    static let rawStreamTables = [
        "hrSample", "rrInterval", "spo2Sample", "skinTempSample", "respSample", "gravitySample",
        "stepSample", "ppgHrSample", "event", "battery", "rawBatch", "sleepStateSample",
        "ppgWaveformSample", "v18AuxSample",
    ]

    /// One-time correction for the first build of the merge above, which moved EVERY table, including the
    /// canonical `my-whoop` imported history and `my-whoop-noop` computed scores, onto the active strap.
    /// Moves the non-raw rows back under the canonical ids, the canonical row winning any clash (the engine
    /// has kept writing fresh computed rows there, so a moved copy is the stale one). Raw streams stay on the
    /// active strap, where they belong.
    ///
    /// Runs only when that build's footprint is present: the active WHOOP is not the canonical id, and the
    /// canonical row is archived with its peripheral cleared. The caller gates it with a one-shot flag.
    /// Returns true when it moved anything back.
    @discardableResult
    public func restoreCanonicalHistoryAfterFullMerge() throws -> Bool {
        let canonical = "my-whoop"
        return try dbQueue.write { db in
            guard let activeId = try String.fetchOne(db, sql: Self.activeDeviceIdSQL), activeId != canonical,
                  let row = try Row.fetchOne(db, sql: "SELECT status, peripheralId FROM pairedDevice WHERE id = ?",
                                             arguments: [canonical]),
                  (row["status"] as String?) == DeviceStatus.archived.rawValue,
                  (row["peripheralId"] as String?) == nil else { return false }
            let raw = Set(Self.rawStreamTables)
            var moved = 0
            for table in Self.deviceScopedTables where !raw.contains(table) {
                try db.execute(sql: "UPDATE OR IGNORE \(table) SET deviceId = ? WHERE deviceId = ?",
                               arguments: [canonical, activeId])
                moved += db.changesCount
                try db.execute(sql: "DELETE FROM \(table) WHERE deviceId = ?", arguments: [activeId])
            }
            let (fromNoop, toNoop) = (activeId + Self.computedSuffix, canonical + Self.computedSuffix)
            for table in Self.deviceScopedTables {
                try db.execute(sql: "UPDATE OR IGNORE \(table) SET deviceId = ? WHERE deviceId = ?",
                               arguments: [toNoop, fromNoop])
                moved += db.changesCount
                try db.execute(sql: "DELETE FROM \(table) WHERE deviceId = ?", arguments: [fromNoop])
            }
            try db.execute(sql: "UPDATE OR IGNORE scoreInputProvenance SET sourceId = ? WHERE sourceId = ?",
                           arguments: [toNoop, fromNoop])
            try db.execute(sql: "DELETE FROM scoreInputProvenance WHERE sourceId = ?", arguments: [fromNoop])
            return moved > 0
        }
    }
}
