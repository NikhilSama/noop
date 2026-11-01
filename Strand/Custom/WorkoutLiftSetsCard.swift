import SwiftUI
import StrandDesign
import WhoopStore

// nikhil/custom — the sets card on a strength workout's detail screen. When a Lift Log session belongs to
// the workout (logged live, or added afterwards with "Log what you did") it summarises the sets and opens
// the session; when none does, it offers to log them from a typed or spoken description.

/// Lift sessions filed AFTER their workout was recorded, by the workout's natural key. Deleting such a
/// session must leave the workout alone: it was recorded on its own, not created by the session.
enum LiftSessionAttachment {
    static let key = "custom.liftSessionAttached.v1"

    private static func token(_ startTs: Int, _ sport: String) -> String { "\(startTs)|\(sport)" }

    static func mark(startTs: Int, sport: String, defaults: UserDefaults = .standard) {
        var all = defaults.stringArray(forKey: key) ?? []
        let t = token(startTs, sport)
        guard !all.contains(t) else { return }
        all.append(t)
        defaults.set(all, forKey: key)
    }

    static func unmark(startTs: Int, sport: String, defaults: UserDefaults = .standard) {
        let t = token(startTs, sport)
        defaults.set((defaults.stringArray(forKey: key) ?? []).filter { $0 != t }, forKey: key)
    }

    static func isAttached(startTs: Int, sport: String, defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: key) ?? []).contains(token(startTs, sport))
    }

    /// The session that belongs to `workout`: the one pinned to its exact key, else a live Lift Log
    /// session that covers most of it (its Watch workout starts a few seconds off the session's).
    static func session(for workout: WorkoutRow, in sessions: [LiftSessionRow]) -> LiftSessionRow? {
        if let exact = sessions.first(where: { $0.startTs == workout.startTs && $0.sport == workout.sport }) {
            return exact
        }
        return sessions.first { s in
            LiftWatchWorkout.overlapsMostly(s.startTs, s.endTs ?? workout.endTs, workout.startTs, workout.endTs)
        }
    }
}

struct WorkoutLiftSetsCard: View {
    let row: WorkoutRow

    /// Sports whose workouts can carry sets: the strength names NOOP, Apple Health and WHOOP imports use,
    /// plus the generic "Workout" / "Activity" a Watch session can arrive as.
    static let sports: Set<String> = [
        "Strength Training", "Functional Fitness", "Weightlifting", "Strength Trainer", "Powerlifting",
        "Functional Strength Training", "Traditional Strength Training", "CrossFit", "Workout", "Activity",
    ]

    static func applies(to sport: String) -> Bool { sports.contains(sport) }

    @EnvironmentObject private var repo: Repository
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    @State private var session: LiftSessionRow?
    @State private var sets: [LiftSetRow] = []
    @State private var loaded = false
    @State private var logging = false
    @State private var opened: OpenedSession?

    /// The session being read back, wrapped as the Lift Log does rather than making the store row
    /// `Identifiable`.
    private struct OpenedSession: Identifiable {
        let session: LiftSessionRow
        var id: String { session.id }
    }

    var body: some View {
        Group {
            if loaded {
                NoopCard {
                    if let session { attached(session) } else { empty }
                }
            } else {
                // A real (zero-height) view while loading: modifiers on a Group with no content are
                // dropped, so an empty branch here would never run the `.task` that loads the card.
                Color.clear.frame(height: 0)
            }
        }
        .task { await load() }
        .sheet(isPresented: $logging) {
            LiftSessionCoachLogSheet(workout: row) { await load() }
        }
        .sheet(item: $opened) { target in
            LiftSessionDetailSheet(session: target.session) { await load() }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sets").strandOverline()
            Text("What did you do?")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Tell Coach the exercises, sets, reps and weights, typed or spoken. They're saved as a Lift Log session on this workout.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            NoopButton("Log what you did", systemImage: "text.bubble", fullWidth: true) { logging = true }
                .padding(.top, 4)
        }
    }

    private func attached(_ session: LiftSessionRow) -> some View {
        let performed = sets.filter { ($0.reps ?? 0) > 0 }
        let groups = Self.groups(performed)
        let volume = performed.compactMap(\.volumeKg).reduce(0, +)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Sets").strandOverline()
            if let name = session.programName, !name.isEmpty {
                Text(name)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            Text(summary(exercises: groups.count, sets: performed.count, volumeKg: volume))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            ForEach(Array(groups.prefix(8).enumerated()), id: \.offset) { _, g in
                HStack(alignment: .firstTextBaseline) {
                    Text(g.exercise)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 8)
                    Text(line(g.sets))
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            if groups.count > 8 {
                Text("+\(groups.count - 8) more")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            NoopButton("Open session", systemImage: "dumbbell", kind: .secondary, fullWidth: true) { opened = OpenedSession(session: session) }
                .padding(.top, 4)
        }
    }

    private func summary(exercises: Int, sets: Int, volumeKg: Double) -> String {
        var parts = ["\(exercises) \(exercises == 1 ? "exercise" : "exercises")", "\(sets) \(sets == 1 ? "set" : "sets")"]
        if volumeKg > 0 { parts.append("\(LiftFormat.weight(volumeKg, system: unitSystem)) volume") }
        return parts.joined(separator: " · ")
    }

    /// "10, 10, 9 × 40 kg" when every set shares a weight, else each set as "reps×weight".
    private func line(_ sets: [LiftSetRow]) -> String {
        let reps = sets.map { "\($0.reps ?? 0)" }
        let weights = Set(sets.map(\.weightKg))
        if weights.count == 1, let only = weights.first {
            guard let kg = only else { return "\(reps.joined(separator: ", ")) reps" }
            return "\(reps.joined(separator: ", ")) × \(LiftFormat.weight(kg, system: unitSystem))"
        }
        return sets.map { s in
            guard let kg = s.weightKg else { return "\(s.reps ?? 0)" }
            return "\(s.reps ?? 0)×\(LiftFormat.trim(LiftFormat.display(fromKilograms: kg, system: unitSystem)))"
        }.joined(separator: ", ")
    }

    /// Consecutive sets of one exercise, in the order performed.
    private static func groups(_ sets: [LiftSetRow]) -> [(exercise: String, sets: [LiftSetRow])] {
        var out: [(exercise: String, sets: [LiftSetRow])] = []
        for s in sets.sorted(by: { $0.ord < $1.ord }) {
            if let last = out.last, last.exercise == s.exercise {
                out[out.count - 1].sets.append(s)
            } else {
                out.append((s.exercise, [s]))
            }
        }
        return out
    }

    private func load() async {
        guard let store = await repo.storeHandle() else { loaded = true; return }
        // A live session's Watch workout can start a little after it; four hours back covers any session
        // that could still cover most of this workout.
        let candidates = (try? await store.liftSessions(deviceId: repo.deviceId,
                                                        fromTs: row.startTs - 4 * 3600,
                                                        toTs: row.endTs)) ?? []
        session = LiftSessionAttachment.session(for: row, in: candidates)
        if let session {
            sets = (try? await store.liftSets(sessionId: session.id)) ?? []
        } else {
            sets = []
        }
        loaded = true
    }
}
