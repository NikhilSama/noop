import SwiftUI
import StrandDesign
import WhoopStore

// nikhil/custom — the two inputs the Coach lift sheets share: a text box that can also be dictated into
// ("Import with Coach" for a program, "Log what you did" for a finished session), and the primary plus
// secondary muscle pickers used on each reviewed exercise.

/// A multi-line text box with a mic button on iOS. Dictation appends to what was already typed. Becoming
/// `disabled` (the sheet starts sending the text) stops a running dictation, keeping what was heard.
struct CoachDictationField: View {
    @Binding var text: String
    var placeholder: LocalizedStringKey
    var disabled: Bool = false

    #if os(iOS)
    @StateObject private var voice = CoachVoiceInput()
    /// What was typed before the mic started, so dictation appends instead of replacing it.
    @State private var voiceBase = ""
    #endif

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(5...14)
                .disabled(disabled)
            #if os(iOS)
            micButton
            #endif
        }
        #if os(iOS)
        .onChange(of: disabled) { _, now in
            if now, voice.isRecording { voice.stopTranscribing { _ in } }
        }
        .onDisappear {
            if voice.isRecording { voice.stopTranscribing { _ in } }
        }
        #endif
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
        .disabled(disabled || !(voice.canUseVoice || voice.authorization == .notDetermined))
        .accessibilityLabel(voice.isRecording ? "Stop dictation" : "Dictate")
        .task {
            if voice.authorization == .notDetermined { voice.requestAuthorization { _ in } }
        }
    }

    private func toggleVoice() {
        if voice.isRecording {
            voice.stopTranscribing { final in
                let spoken = final.trimmingCharacters(in: .whitespacesAndNewlines)
                if !spoken.isEmpty { text = voiceBase.isEmpty ? spoken : "\(voiceBase) \(spoken)" }
            }
            return
        }
        voiceBase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = {
            voice.startTranscribing { partial in
                text = voiceBase.isEmpty ? partial : "\(voiceBase) \(partial)"
            }
        }
        if voice.authorization == .notDetermined {
            voice.requestAuthorization { state in if state == .authorized { start() } }
        } else {
            start()
        }
    }
    #endif
}

/// The main muscle as a menu, and the also-worked muscles as a menu of toggles. The primary is never
/// offered as a secondary, and picking a primary that was listed as secondary moves it.
struct LiftMusclePickers: View {
    @Binding var primary: LiftMuscle?
    @Binding var secondary: [LiftMuscle]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Muscle", selection: Binding(get: { primary }, set: { new in
                primary = new
                secondary.removeAll { $0 == new }
            })) {
                Text("Unclassified").tag(LiftMuscle?.none)
                ForEach(LiftMuscle.allCases, id: \.self) { m in
                    Text(m.displayName).tag(LiftMuscle?.some(m))
                }
            }
            .pickerStyle(.menu)
            .tint(StrandPalette.accent)
            .font(StrandFont.footnote)

            Menu {
                ForEach(LiftMuscle.allCases.filter { $0 != primary }, id: \.self) { m in
                    Button {
                        if let i = secondary.firstIndex(of: m) { secondary.remove(at: i) } else { secondary.append(m) }
                    } label: {
                        if secondary.contains(m) {
                            Label(m.displayName, systemImage: "checkmark")
                        } else {
                            Text(m.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Also works:")
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text(secondary.isEmpty ? "none" : secondary.map(\.displayName).joined(separator: ", "))
                        .foregroundStyle(StrandPalette.accent)
                        .multilineTextAlignment(.leading)
                }
                .font(StrandFont.footnote)
            }
        }
    }
}
