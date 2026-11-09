import SwiftUI
import UniformTypeIdentifiers
import StrandDesign

// nikhil/custom — Settings → Features: the Nutrition switch and the one-time HealthVault import.
struct NutritionSettingsRows: View {
    @EnvironmentObject private var repo: Repository
    @AppStorage(NutritionPrefs.enabledKey) private var enabled = false
    @State private var importing = false
    @State private var running = false
    @State private var result: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2 + 2) {
            Toggle(isOn: $enabled) {
                Text("Nutrition tracking")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            .toggleStyle(.switch)
            .tint(StrandPalette.accent)

            Text("Calories in from your recipes and standard day, against calories out (resting, digestion, active). Stored on this device and included in backups.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if enabled {
                HStack(spacing: NoopMetrics.space3) {
                    Button { importing = true } label: {
                        Label(running ? "Importing…" : "Import vault file…", systemImage: "tray.and.arrow.down")
                    }
                    .buttonStyle(NoopButtonStyle(.secondary))
                    .disabled(running)
                    if running { ProgressView().controlSize(.small) }
                }
                if let result {
                    Text(result).font(StrandFont.caption)
                        .foregroundStyle(failed ? StrandPalette.statusWarning : StrandPalette.statusPositive)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { picked in
            guard case .success(let url) = picked else { return }
            Task { await run(url) }
        }
    }

    private func run(_ url: URL) async {
        running = true
        defer { running = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            result = try await repo.importNutrition(data)
            failed = false
        } catch {
            result = String(localized: "Import failed: \(error.localizedDescription)")
            failed = true
        }
    }
}
