import SwiftUI
import StrandDesign

// nikhil/custom: the morning journal.
//
// When "Ask on first open each day" is on, the first time the app comes to the foreground on a new local
// day it opens the journal for today. Questions with a saved default show it pre-marked, so a usual day
// is one tap: "Good to go" logs the default for every question still unanswered. Change only what was
// different, then tap it. "Skip today" closes without logging; either way it does not ask again today.

enum JournalDailyPromptPrefs {
    /// Settings toggle (default off).
    static let enabledKey = "journal.dailyPrompt.enabled"
    /// Local day key (yyyy-MM-dd) the app was last foregrounded on, so only the FIRST open asks.
    static let lastOpenDayKey = "journal.dailyPrompt.lastOpenDay"
    /// Opens before this local hour count as last night, not the first open of the new day.
    static let dayStartHour = 4
    /// DEMO ONLY: show the sheet on every launch, ignoring the toggle and the once-a-day checks.
    static let demoAlwaysShow = true
}

enum JournalDefaults {
    /// Log each default for a question the day has no answer to. Returns how many were logged.
    @MainActor @discardableResult
    static func apply(day: String, repo: Repository, importedQuestions: [String],
                      answers: [String: Bool], numericAnswers: [String: Double]) async -> Int {
        let items = JournalCatalogStore().resolvedItems(imported: importedQuestions)
        var logged = 0
        for item in items {
            guard let value = item.defaultValue else { continue }
            if item.kind.isNumeric {
                guard numericAnswers[item.canonical] == nil else { continue }
                await repo.saveJournalNumeric(day: day, question: item.canonical, value: value)
            } else {
                guard answers[item.canonical] == nil else { continue }
                await repo.saveJournalAnswer(day: day, question: item.canonical, answeredYes: value >= 0.5)
            }
            logged += 1
        }
        return logged
    }

    /// The export's exact question strings, so defaults land on the same keys imported history uses.
    static func importedQuestions(repo: Repository) async -> [String] {
        let imported = await repo.importedJournalEntries()
        return NSOrderedSet(array: imported.map(\.question)).array as? [String] ?? []
    }
}

/// The sheet: today's journal (defaults pre-marked) with "Good to go" / "Skip today".
struct JournalDailyPromptSheet: View {
    @EnvironmentObject var repo: Repository
    let onClose: () -> Void

    @State private var importedQuestions: [String] = []
    @State private var answers: [String: Bool] = [:]
    @State private var numericAnswers: [String: Double] = [:]
    @State private var dayOffset = 0
    @State private var saving = false

    private var dayKey: String {
        Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date()) ?? Date())
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    JournalLogCard(importedQuestions: importedQuestions, answers: answers,
                                   numericAnswers: numericAnswers, dayOffset: $dayOffset, compact: true,
                                   onChanged: { Task { await load() } })
                }
                .screenPadding()
                .padding(.vertical, NoopMetrics.space4)
            }
            VStack(spacing: 8) {
                NoopButton("Good to go", systemImage: "checkmark", kind: .primary, fullWidth: true) {
                    guard !saving else { return }
                    saving = true
                    Task {
                        await JournalDefaults.apply(day: dayKey, repo: repo, importedQuestions: importedQuestions,
                                                    answers: answers, numericAnswers: numericAnswers)
                        onClose()
                    }
                }
                Button("Skip today", action: onClose)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .buttonStyle(.plain)
            }
            .screenPadding()
            .padding(.vertical, NoopMetrics.space4)
            .background(StrandPalette.surfaceBase)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 640)
        #endif
        .task { await load() }
    }

    private func load() async {
        if importedQuestions.isEmpty { importedQuestions = await JournalDefaults.importedQuestions(repo: repo) }
        answers = await repo.nativeJournalAnswers(day: dayKey)
        numericAnswers = await repo.nativeJournalNumeric(day: dayKey)
    }
}

/// Presents the sheet on the first foreground of a new local day, when enabled and today is unlogged.
struct JournalDailyPromptModifier: ViewModifier {
    @EnvironmentObject var repo: Repository
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(JournalDailyPromptPrefs.enabledKey) private var enabled = false
    @AppStorage(JournalDailyPromptPrefs.lastOpenDayKey) private var lastOpenDay = ""
    @AppStorage("noop.onboarded") private var onboarded = false
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                if JournalDailyPromptPrefs.demoAlwaysShow, onboarded { showing = true } else { check() }
            }
            .onChangeCompat(of: scenePhase) { phase in if phase == .active { check() } }
            .sheet(isPresented: $showing) {
                JournalDailyPromptSheet(onClose: { showing = false })
                    .environmentObject(repo)
            }
    }

    private func check() {
        let now = Date()
        guard Calendar.current.component(.hour, from: now) >= JournalDailyPromptPrefs.dayStartHour else { return }
        let today = Repository.localDayKey(now)
        guard lastOpenDay != today else { return }
        lastOpenDay = today
        guard enabled, onboarded, !showing else { return }
        Task {
            let logged = await repo.nativeJournalDays(from: today, to: today)
            if !logged.contains(today) { showing = true }
        }
    }
}

extension View {
    /// nikhil/custom: the once-a-day morning journal (see JournalDailyPromptModifier).
    func journalDailyPrompt() -> some View { modifier(JournalDailyPromptModifier()) }
}
