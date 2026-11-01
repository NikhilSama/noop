import SwiftUI
import StrandDesign
import WhoopStore

// nikhil/custom — "Log what you did": after a strength workout has been recorded (Watch, the phone's live
// workout, or added by hand), describe the session in words, typed or spoken, and the Coach's model turns
// it into the sets actually performed. Three steps in one sheet: describe, review and edit, save.
//
// The reverse of running a Lift Log program: the workout already exists, so nothing new is written to the
// workout table. Saving files a Lift Log session pinned to that workout by its natural key (start time and
// sport, the same pairing a live session uses), so the sets show in the Lift Log with the heart-rate
// figures the workout measured. Only the description leaves the phone.

struct LiftSessionCoachLogSheet: View {
    /// The recorded workout the sets attach to.
    let workout: WorkoutRow
    /// Called after the session has been written.
    var onSaved: () async -> Void

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var coach: AICoachEngine
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    @State private var description = ""
    @State private var working = false
    @State private var failure: String?
    @State private var draft: SessionDraft?
    @State private var warnings: [String] = []
    @State private var saving = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    if let draft {
                        review(draft)
                    } else {
                        describeStep
                    }
                    if let failure {
                        NoopCard {
                            Text(failure)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.statusCritical)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(NoopMetrics.screenPadding)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle("Log what you did")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if draft != nil {
                        Button("Save") { Task { await save() } }
                            .disabled(saving || !(draft?.isSavable ?? false))
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 560, height: 720)
        #endif
    }

    // MARK: - Step 1: describe

    private var workoutLabel: String {
        let start = Date(timeIntervalSince1970: TimeInterval(workout.startTs))
        let minutes = max(0, workout.endTs - workout.startTs) / 60
        return "\(start.formatted(date: .abbreviated, time: .shortened)) · \(minutes) min"
    }

    private var describeStep: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What did you do?")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(workoutLabel)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Text("Type it or tap the mic and say it, for example: \"Squats, 3 sets of 10 at 40 kg. Then lunges, 3 by 12 with no weight, the last set only 9. Finished with cable rows, 2 sets of 15 at 25.\" You can review and edit everything before it's saved.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            NoopCard {
                CoachDictationField(text: $description, placeholder: "Exercises, sets, reps, weights…",
                                    disabled: working)
            }

            if coach.isConfigured {
                Button {
                    Task { await build() }
                } label: {
                    HStack(spacing: 8) {
                        if working { ProgressView().controlSize(.small) }
                        Text(working ? "Reading your sets…" : "Build the session")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.noopPrimary)
                .disabled(working || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Text("Only this description is sent, to \(coach.provider.displayName) with your Coach key. No health data goes with it.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                NoopCard {
                    Text("Set up Coach first: this uses the model and API key from the Coach tab.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func build() async {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !working else { return }
        working = true
        failure = nil
        defer { working = false }
        do {
            let reply = try await coach.oneShot(systemPrompt: CoachSessionParser.systemPrompt, text: text)
            let parsed = try CoachSessionParser.parse(reply)
            let known = (try? await repo.storeHandle()?.liftExercises(deviceId: repo.deviceId)) ?? []
            draft = SessionDraft(parsed.session, known: known, system: unitSystem)
            warnings = parsed.warnings
        } catch let error as CoachProgramParser.ParseError {
            failure = error == .empty
                ? String(localized: "Coach couldn't find any exercises in that. Try naming each exercise with its sets and reps.")
                : String(localized: "Coach's reply wasn't a session it could read. Try again, or rephrase the description.")
        } catch {
            failure = error.localizedDescription
        }
    }

    // MARK: - Step 2: review and edit

    private func review(_ current: SessionDraft) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Session name").strandOverline()
                    TextField("Session name", text: binding(\.name))
                        .textFieldStyle(.plain)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(workoutLabel)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Text("Check each exercise and set, change anything Coach got wrong, then Save. Sets left without reps aren't saved.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ForEach(current.exercises) { ex in
                exerciseCard(ex.id)
            }

            Button {
                draft?.exercises.append(SessionDraft.Exercise())
            } label: {
                Label("Add exercise", systemImage: "plus")
            }
            .buttonStyle(NoopButtonStyle(.secondary))

            if !warnings.isEmpty {
                NoopCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Worth checking")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.statusWarning)
                        ForEach(Array(warnings.enumerated()), id: \.offset) { _, w in
                            Text(w)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Button {
                draft = nil
                warnings = []
                failure = nil
            } label: {
                Label("Change the description", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(NoopButtonStyle(.secondary))
        }
    }

    private func exerciseCard(_ id: UUID) -> some View {
        let sets = draft?.exercises.first { $0.id == id }?.sets ?? []
        return NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("Exercise", text: exerciseBinding(id, \.exercise))
                        .textFieldStyle(.plain)
                        .font(StrandFont.body.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Button {
                        draft?.exercises.removeAll { $0.id == id }
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove this exercise")
                }
                LiftMusclePickers(primary: exerciseBinding(id, \.primary),
                                  secondary: exerciseBinding(id, \.secondary))

                HStack(spacing: 10) {
                    Text("Set").strandOverline().frame(width: 30, alignment: .leading)
                    Text(LocalizedStringKey(LiftFormat.weightUnit(unitSystem))).strandOverline()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Reps").strandOverline().frame(maxWidth: .infinity, alignment: .leading)
                    Text("Warm-up").strandOverline().frame(width: 58)
                    Color.clear.frame(width: 22, height: 1)
                }
                ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
                    setRow(exercise: id, set: set.id, number: index + 1)
                }
                Button {
                    guard let i = draft?.exercises.firstIndex(where: { $0.id == id }) else { return }
                    var next = SessionDraft.SetLine()
                    if let last = draft?.exercises[i].sets.last {
                        next.weight = last.weight
                        next.reps = last.reps
                    }
                    draft?.exercises[i].sets.append(next)
                } label: {
                    Label("Add set", systemImage: "plus")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func setRow(exercise: UUID, set: UUID, number: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 30, alignment: .leading)
            TextField("–", text: setBinding(exercise, set, \.weight))
                .textFieldStyle(.plain)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .numericKeyboard()
                .frame(maxWidth: .infinity, alignment: .leading)
            TextField("–", text: setBinding(exercise, set, \.reps))
                .textFieldStyle(.plain)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .numericKeyboard()
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Warm-up", isOn: setBinding(exercise, set, \.warmup))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(StrandPalette.accent)
                .frame(width: 58)
            Button {
                guard let i = draft?.exercises.firstIndex(where: { $0.id == exercise }) else { return }
                draft?.exercises[i].sets.removeAll { $0.id == set }
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .frame(width: 22)
            .accessibilityLabel("Remove set \(number)")
        }
    }

    private func binding<T>(_ path: WritableKeyPath<SessionDraft, T>) -> Binding<T> {
        Binding(get: { (draft ?? .empty)[keyPath: path] }, set: { draft?[keyPath: path] = $0 })
    }

    private func exerciseBinding<T>(_ id: UUID, _ path: WritableKeyPath<SessionDraft.Exercise, T>) -> Binding<T> {
        Binding(
            // A row being removed can be read once more as it leaves; it reads as a blank one then.
            get: { (draft?.exercises.first { $0.id == id } ?? SessionDraft.Exercise())[keyPath: path] },
            set: { value in
                guard let i = draft?.exercises.firstIndex(where: { $0.id == id }) else { return }
                draft?.exercises[i][keyPath: path] = value
            })
    }

    private func setBinding<T>(_ exercise: UUID, _ set: UUID,
                               _ path: WritableKeyPath<SessionDraft.SetLine, T>) -> Binding<T> {
        Binding(
            get: {
                let line = draft?.exercises.first { $0.id == exercise }?.sets.first { $0.id == set }
                return (line ?? SessionDraft.SetLine())[keyPath: path]
            },
            set: { value in
                guard let i = draft?.exercises.firstIndex(where: { $0.id == exercise }),
                      let j = draft?.exercises[i].sets.firstIndex(where: { $0.id == set }) else { return }
                draft?.exercises[i].sets[j][keyPath: path] = value
            })
    }

    // MARK: - Step 3: save

    private func save() async {
        guard let draft, draft.isSavable, !saving, let store = await repo.storeHandle() else { return }
        saving = true
        defer { saving = false }

        let logged = draft.session(system: unitSystem)
        let row = LiftSessionRow(
            id: UUID().uuidString, deviceId: repo.deviceId,
            startTs: workout.startTs, endTs: workout.endTs, sport: workout.sport,
            programId: nil, programName: logged.name, sessionRpe: nil, note: logged.note)
        do {
            _ = try await store.upsertLiftSessions([row])
            // The store keys sessions on (deviceId, startTs, sport) and keeps the first id it saw, so the
            // sets must hang off the id it actually holds.
            let stored = try await store.liftSessions(deviceId: repo.deviceId,
                                                      fromTs: workout.startTs, toTs: workout.startTs)
            guard let sessionId = stored.first(where: { $0.sport == workout.sport })?.id else {
                failure = String(localized: "The session couldn't be saved. Try again.")
                return
            }
            _ = try await store.upsertLiftSets(LiftSessionCoachLog.setRows(
                logged, sessionId: sessionId, deviceId: repo.deviceId))
        } catch {
            failure = String(localized: "The session couldn't be saved. Try again.")
            return
        }
        LiftSessionAttachment.mark(startTs: workout.startTs, sport: workout.sport)

        // Best-effort, as in the program import: a full vocabulary must not fail the session itself. The
        // review step already started each known exercise from the user's own muscles.
        let now = Int(Date().timeIntervalSince1970)
        _ = try? await store.upsertLiftExercises(logged.exercises.map { ex in
            LiftExerciseRow(id: UUID().uuidString, deviceId: repo.deviceId, name: ex.exercise,
                            primaryMuscle: ex.primaryMuscle, secondaryMuscles: ex.secondaryMuscles,
                            createdAt: now, lastUsedTs: workout.startTs)
        })

        await onSaved()
        dismiss()
    }
}

// MARK: - Rows

enum LiftSessionCoachLog {
    /// The set rows for a logged session: performed order across the session, `setIndex` counted per
    /// exercise name (an exercise returned to later carries on its numbering), and sets with no reps left
    /// out, since a set that was not done has nothing to count.
    static func setRows(_ session: LoggedSession, sessionId: String, deviceId: String) -> [LiftSetRow] {
        var rows: [LiftSetRow] = []
        var perExercise: [String: Int] = [:]
        for ex in session.exercises {
            for set in ex.sets {
                guard let reps = set.reps, reps > 0 else { continue }
                let index = (perExercise[ex.exercise] ?? 0) + 1
                perExercise[ex.exercise] = index
                rows.append(LiftSetRow(
                    id: UUID().uuidString, deviceId: deviceId, sessionId: sessionId,
                    ord: rows.count, exercise: ex.exercise,
                    primaryMuscle: ex.primaryMuscle, secondaryMuscles: ex.secondaryMuscles,
                    setIndex: index, weightKg: set.weightKg, reps: reps, rpe: nil,
                    isWarmup: set.isWarmup, startTs: nil, endTs: nil, restSec: nil, note: nil))
            }
        }
        return rows
    }
}

// MARK: - Editable draft

/// The session as the review step edits it: numbers held as the text in each field, weight in the user's
/// own unit, converted back to kilograms only when the session is built for saving.
private struct SessionDraft {
    var name: String
    var note: String?
    var exercises: [Exercise]

    struct Exercise: Identifiable {
        let id = UUID()
        var exercise = ""
        var primary: LiftMuscle?
        var secondary: [LiftMuscle] = []
        var sets: [SetLine] = [SetLine()]
    }

    struct SetLine: Identifiable {
        let id = UUID()
        var weight = ""
        var reps = ""
        var warmup = false
    }

    static let empty = SessionDraft(name: "", note: nil, exercises: [])

    init(name: String, note: String?, exercises: [Exercise]) {
        self.name = name
        self.note = note
        self.exercises = exercises
    }

    /// Exercises already in the log keep their spelling and the muscles the user gave them.
    init(_ session: LoggedSession, known: [LiftExerciseRow], system: UnitSystem) {
        name = session.name
        note = session.note
        exercises = session.exercises.map { e in
            var ex = Exercise()
            ex.exercise = e.exercise
            ex.primary = e.primaryMuscle
            ex.secondary = e.secondaryMuscles
            if let k = CoachVocabulary.lookup(e.exercise, in: known) {
                ex.exercise = k.name
                if k.primaryMuscle != nil || !k.secondaryMuscles.isEmpty {
                    ex.primary = k.primaryMuscle
                    ex.secondary = k.secondaryMuscles
                }
            }
            ex.sets = e.sets.map { s in
                var line = SetLine()
                line.weight = s.weightKg.map {
                    LiftFormat.trim(LiftFormat.display(fromKilograms: $0, system: system))
                } ?? ""
                line.reps = s.reps.map(String.init) ?? ""
                line.warmup = s.isWarmup
                return line
            }
            return ex
        }
    }

    var isSavable: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && exercises.contains { ex in
                !ex.exercise.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && ex.sets.contains { Self.reps($0.reps) != nil }
            }
    }

    private static func reps(_ s: String) -> Int? {
        LiftFormat.number(s).map { Int($0.rounded()) }.flatMap { $0 > 0 ? $0 : nil }
    }

    func session(system: UnitSystem) -> LoggedSession {
        LoggedSession(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            note: note,
            exercises: exercises.compactMap { ex in
                let name = ex.exercise.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                return LoggedExercise(
                    exercise: name,
                    primaryMuscle: ex.primary,
                    secondaryMuscles: ex.secondary.filter { $0 != ex.primary },
                    sets: ex.sets.map { s in
                        LoggedSet(weightKg: LiftFormat.number(s.weight).map {
                                      LiftFormat.kilograms(fromDisplay: $0, system: system)
                                  },
                                  reps: Self.reps(s.reps),
                                  isWarmup: s.warmup)
                    })
            })
    }
}
