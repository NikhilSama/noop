import SwiftUI
import StrandDesign
import StrandImport
import WhoopStore

// nikhil/custom — "Import with Coach": describe a workout in words, typed or spoken, and the Coach's model
// turns it into a Lift Log program. Three steps in one sheet: describe, review and edit, save.
//
// Only the description leaves the phone, sent to the provider and key already set up in Coach; no health
// data goes with it. Nothing is written until Save, and the write mirrors the spreadsheet import
// (`LiftProgramImportSheet.performImport`): a program row, its ordered items, and the exercises
// remembered in the vocabulary with their muscles.

struct LiftProgramCoachImportSheet: View {
    /// Called after the program has been written, so the Lift Log can reload.
    var onImported: () async -> Void

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var coach: AICoachEngine
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    @State private var description = ""
    @State private var working = false
    @State private var failure: String?
    @State private var draft: Draft?
    @State private var warnings: [String] = []
    @State private var saving = false

    #if os(iOS)
    @StateObject private var voice = CoachVoiceInput()
    /// What was typed before the mic started, so dictation appends instead of replacing it.
    @State private var voiceBase = ""
    #endif

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
            .navigationTitle("Import with Coach")
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
    }

    // MARK: - Step 1: describe

    private var describeStep: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Describe the workout")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Type it or tap the mic and say it, for example: \"Start with back squats, 4 sets of 8 at 80 kg, 2 minutes rest. Then Romanian deadlifts, 3 sets of 10 at 60.\" You can review and edit everything before it's saved.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            NoopCard {
                VStack(alignment: .trailing, spacing: 8) {
                    TextField("Exercises, sets, reps, weights, rest…", text: $description, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(5...14)
                        .disabled(working)
                    #if os(iOS)
                    micButton
                    #endif
                }
            }

            if coach.isConfigured {
                Button {
                    Task { await build() }
                } label: {
                    HStack(spacing: 8) {
                        if working { ProgressView().controlSize(.small) }
                        Text(working ? "Building the program…" : "Build program")
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

    #if os(iOS)
    private var micButton: some View {
        Button {
            toggleVoice()
        } label: {
            Label(voice.isRecording ? "Stop" : "Speak",
                  systemImage: voice.isRecording ? "stop.circle.fill" : "mic.fill")
                .font(StrandFont.subhead)
                .foregroundStyle(voice.isRecording ? StrandPalette.statusCritical : StrandPalette.accent)
        }
        .buttonStyle(.plain)
        .disabled(working || !(voice.canUseVoice || voice.authorization == .notDetermined))
        .accessibilityLabel(voice.isRecording ? "Stop dictation" : "Dictate the workout")
        .task {
            if voice.authorization == .notDetermined { voice.requestAuthorization { _ in } }
        }
    }

    private func toggleVoice() {
        if voice.isRecording {
            voice.stopTranscribing { final in
                let spoken = final.trimmingCharacters(in: .whitespacesAndNewlines)
                if !spoken.isEmpty { description = voiceBase.isEmpty ? spoken : "\(voiceBase) \(spoken)" }
            }
            return
        }
        voiceBase = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = {
            voice.startTranscribing { partial in
                description = voiceBase.isEmpty ? partial : "\(voiceBase) \(partial)"
            }
        }
        if voice.authorization == .notDetermined {
            voice.requestAuthorization { state in if state == .authorized { start() } }
        } else {
            start()
        }
    }
    #endif

    private func build() async {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !working else { return }
        #if os(iOS)
        if voice.isRecording { voice.stopTranscribing { _ in } }
        #endif
        working = true
        failure = nil
        defer { working = false }
        do {
            let reply = try await coach.oneShot(systemPrompt: CoachProgramParser.systemPrompt, text: text)
            let parsed = try CoachProgramParser.parse(reply)
            draft = Draft(parsed.program, system: unitSystem)
            warnings = parsed.warnings
        } catch let error as CoachProgramParser.ParseError {
            failure = error == .empty
                ? String(localized: "Coach couldn't find any exercises in that. Try naming each exercise with its sets and reps.")
                : String(localized: "Coach's reply wasn't a program it could read. Try again, or rephrase the description.")
        } catch {
            failure = error.localizedDescription
        }
    }

    // MARK: - Step 2: review and edit

    private func review(_ current: Draft) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Program name").strandOverline()
                    TextField("Program name", text: binding(\.name))
                        .textFieldStyle(.plain)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Check each exercise, change anything Coach got wrong, then Save.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }

            ForEach(current.lines) { line in
                lineCard(line.id)
            }

            Button {
                draft?.lines.append(Draft.Line())
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

    private func lineCard(_ id: UUID) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("Exercise", text: lineBinding(id, \.exercise))
                        .textFieldStyle(.plain)
                        .font(StrandFont.body.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Button {
                        draft?.lines.removeAll { $0.id == id }
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove this exercise")
                }
                HStack(spacing: 10) {
                    numberField("Sets", lineBinding(id, \.sets))
                    numberField("Reps", lineBinding(id, \.reps))
                    numberField(LocalizedStringKey(LiftFormat.weightUnit(unitSystem)), lineBinding(id, \.weight))
                    numberField("Rest s", lineBinding(id, \.rest))
                }
                Picker("Muscle", selection: lineBinding(id, \.primary)) {
                    Text("Unclassified").tag(LiftMuscle?.none)
                    ForEach(LiftMuscle.allCases, id: \.self) { m in
                        Text(m.displayName).tag(LiftMuscle?.some(m))
                    }
                }
                .pickerStyle(.menu)
                .tint(StrandPalette.accent)
                .font(StrandFont.footnote)
            }
        }
    }

    private func numberField(_ label: LocalizedStringKey, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).strandOverline()
            TextField("–", text: text)
                .textFieldStyle(.plain)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .numericKeyboard()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func binding<T>(_ path: WritableKeyPath<Draft, T>) -> Binding<T> {
        Binding(get: { (draft ?? .empty)[keyPath: path] }, set: { draft?[keyPath: path] = $0 })
    }

    private func lineBinding<T>(_ id: UUID, _ path: WritableKeyPath<Draft.Line, T>) -> Binding<T> {
        Binding(
            // A row being removed can be read once more as it leaves; it reads as a blank line then.
            get: { (draft?.lines.first { $0.id == id } ?? Draft.Line())[keyPath: path] },
            set: { value in
                guard let i = draft?.lines.firstIndex(where: { $0.id == id }) else { return }
                draft?.lines[i][keyPath: path] = value
            })
    }

    // MARK: - Step 3: save

    private func save() async {
        guard let draft, draft.isSavable, !saving, let store = await repo.storeHandle() else { return }
        saving = true
        defer { saving = false }

        let program = draft.program(system: unitSystem)
        let now = Int(Date().timeIntervalSince1970)
        let programId = UUID().uuidString
        do {
            _ = try await store.upsertLiftPrograms([LiftProgramRow(
                id: programId, deviceId: repo.deviceId, name: program.name, note: program.note,
                createdAt: now, updatedAt: now, archived: false)])
            let items = program.lines.enumerated().map { index, line in
                LiftProgramItemRow(
                    id: UUID().uuidString, deviceId: repo.deviceId, programId: programId,
                    ord: index, exercise: line.exercise,
                    targetSets: line.targetSets,
                    targetRepsLow: line.targetReps, targetRepsHigh: nil, targetRpe: line.targetMaxRpe,
                    targetWeightKg: line.targetWeightKg,
                    restSec: line.restSec, note: line.note)
            }
            _ = try await store.replaceLiftProgramItems(programId: programId, items: items)
        } catch {
            failure = String(localized: "The program couldn't be saved. Try again.")
            return
        }
        // Best-effort, as in the spreadsheet import: a full vocabulary must not fail the program itself.
        _ = try? await store.upsertLiftExercises(program.lines.map { line in
            LiftExerciseRow(id: UUID().uuidString, deviceId: repo.deviceId, name: line.exercise,
                            primaryMuscle: line.primaryMuscle, secondaryMuscles: line.secondaryMuscles,
                            createdAt: now, lastUsedTs: nil)
        })

        await onImported()
        dismiss()
    }
}

// MARK: - Editable draft

/// The program as the review step edits it: numbers held as the text in each field, weight in the
/// user's own unit, converted back to kilograms only when the program is built for saving.
private struct Draft {
    var name: String
    var note: String?
    var lines: [Line]

    struct Line: Identifiable {
        let id = UUID()
        var exercise = ""
        var primary: LiftMuscle?
        var secondary: [LiftMuscle] = []
        var sets = ""
        var reps = ""
        var weight = ""
        var rest = ""
        var rpe: Double?
        var note: String?
    }

    static let empty = Draft(name: "", note: nil, lines: [])

    init(name: String, note: String?, lines: [Line]) {
        self.name = name
        self.note = note
        self.lines = lines
    }

    init(_ program: ImportedProgram, system: UnitSystem) {
        name = program.name
        note = program.note
        lines = program.lines.map { l in
            var line = Line()
            line.exercise = l.exercise
            line.primary = l.primaryMuscle
            line.secondary = l.secondaryMuscles
            line.sets = l.targetSets.map(String.init) ?? ""
            line.reps = l.targetReps.map(String.init) ?? ""
            line.weight = l.targetWeightKg.map {
                LiftFormat.trim(LiftFormat.display(fromKilograms: $0, system: system))
            } ?? ""
            line.rest = l.restSec.map(String.init) ?? ""
            line.rpe = l.targetMaxRpe
            line.note = l.note
            return line
        }
    }

    private var namedLines: [Line] {
        lines.filter { !$0.exercise.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var isSavable: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !namedLines.isEmpty
    }

    func program(system: UnitSystem) -> ImportedProgram {
        func int(_ s: String) -> Int? { LiftFormat.number(s).map { Int($0.rounded()) }.flatMap { $0 > 0 ? $0 : nil } }
        return ImportedProgram(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            note: note,
            lines: namedLines.map { l in
                ImportedProgramLine(
                    exercise: l.exercise.trimmingCharacters(in: .whitespacesAndNewlines),
                    primaryMuscle: l.primary,
                    secondaryMuscles: l.secondary.filter { $0 != l.primary },
                    targetSets: int(l.sets),
                    targetReps: int(l.reps),
                    targetWeightKg: LiftFormat.number(l.weight).map {
                        LiftFormat.kilograms(fromDisplay: $0, system: system)
                    },
                    targetMaxRpe: l.rpe,
                    restSec: int(l.rest),
                    note: l.note)
            })
    }
}
