import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import StrandDesign
import WhoopStore

// nikhil/custom — make a recipe from text and/or photos. The Coach's provider estimates a parts table; it is
// reviewed (and corrected, or re-asked with Opus) before anything is saved. Without a Coach key the parts can
// be typed in instead. Totals are always the sum of the parts.
struct NutritionEstimateSheet: View {
    var initialText = ""
    /// Saved as a one-off (made while logging a day) rather than a regular recipe.
    let oneOff: Bool
    /// An existing recipe to edit instead of estimating a new one.
    var editing: NutritionRecipe?
    let onSaved: (NutritionRecipe) -> Void

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var coach: AICoachEngine
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var photos: [Data] = []
    @State private var estimate: NutritionEstimator.Estimate?
    @State private var correction = ""
    @State private var working = false
    @State private var error: String?
    @State private var editingPart: Int?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    if estimate == nil { inputSection } else { reviewSection }
                    if let error {
                        Text(error).font(StrandFont.footnote).foregroundStyle(StrandPalette.statusWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(NoopMetrics.screenPadding)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(editing == nil ? "New food" : "Edit recipe")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if estimate != nil {
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } } }
                }
            }
            .sheet(item: Binding(get: { editingPart.map(PartRef.init) }, set: { editingPart = $0?.index })) { ref in
                if let estimate, estimate.parts.indices.contains(ref.index) {
                    PartEditor(part: estimate.parts[ref.index]) { updated in
                        if let updated { self.estimate?.parts[ref.index] = updated } else { self.estimate?.parts.remove(at: ref.index) }
                        editingPart = nil
                    }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 560)
        .onAppear {
            if text.isEmpty { text = initialText }
            if let editing, estimate == nil {
                estimate = .init(name: editing.name, serving: editing.serving,
                                 parts: editing.parts.isEmpty ? [NutritionRecipePart(name: editing.name, macros: editing.macros)] : editing.parts,
                                 notes: editing.notes)
                text = editing.sourceText ?? ""
            }
        }
        .onChangeCompat(of: photoItems) { items in Task { await loadPhotos(items) } }
    }

    private struct PartRef: Identifiable { let index: Int; var id: Int { index } }

    // MARK: Input

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("Describe it, paste a recipe, or add photos of the plate or the nutrition label.")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(StrandFont.body)
                .frame(minHeight: 120)
                .padding(6)
                .background(NoopPanelSurface(cornerRadius: 12))
            HStack(spacing: NoopMetrics.space3) {
                PhotosPicker(selection: $photoItems, maxSelectionCount: 4, matching: .images) {
                    Label(photos.isEmpty ? "Add photos" : "\(photos.count) photo(s)", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(NoopButtonStyle(.secondary))
                Spacer()
            }
            if coach.isConfigured {
                NoopButton(working ? "Estimating…" : "Estimate", kind: .primary, fullWidth: true) {
                    Task { await run(useOpus: false) }
                }
                .disabled(working || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photos.isEmpty))
                Text("Only this text and these photos go to \(coach.provider.displayName) with your Coach key.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            } else {
                Text("Set up the Coach in Settings to estimate with AI, or enter the numbers yourself.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            NoopButton("Enter numbers myself", kind: .secondary, fullWidth: true) {
                let name = text.split(separator: "\n").first.map(String.init) ?? ""
                estimate = .init(name: name.isEmpty ? String(localized: "Food") : name, serving: "1 serving",
                                 parts: [NutritionRecipePart(name: name.isEmpty ? String(localized: "Food") : name,
                                                             macros: .zero)], notes: "")
                editingPart = 0
            }
        }
    }

    // MARK: Review

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            if let binding = Binding($estimate) {
                TextField("Name", text: binding.name).font(StrandFont.title2)
                TextField("Serving", text: binding.serving).font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            if let e = estimate {
                totalsRow(e.totals)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(e.parts.enumerated()), id: \.offset) { i, part in
                        Button { editingPart = i } label: {
                            HStack {
                                Text(part.name).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                                Text("\(Int(part.macros.kcal.rounded())) kcal · \(Self.g(part.macros.proteinG)) P")
                                    .font(StrandFont.caption).monospacedDigit().foregroundStyle(StrandPalette.textSecondary)
                            }
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                    Button {
                        estimate?.parts.append(NutritionRecipePart(name: String(localized: "New part"), macros: .zero))
                        editingPart = (estimate?.parts.count ?? 1) - 1
                    } label: { Label("Add part", systemImage: "plus") }
                    .font(StrandFont.subhead).padding(.top, 8)
                }
                if !e.notes.isEmpty {
                    Text(e.notes).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if coach.isConfigured && editing == nil {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        TextField("Correction, e.g. it was 2 eggs, not 3", text: $correction, axis: .vertical)
                            .font(StrandFont.subhead)
                            .padding(8).background(NoopPanelSurface(cornerRadius: 10))
                        HStack(spacing: NoopMetrics.space2) {
                            NoopButton(working ? "Working…" : "Re-estimate", kind: .secondary, fullWidth: true) {
                                Task { await run(useOpus: false) }
                            }
                            if coach.provider == .anthropic {
                                NoopButton("With Opus", kind: .secondary, fullWidth: true) { Task { await run(useOpus: true) } }
                            }
                        }
                        .disabled(working)
                    }
                }
            }
        }
    }

    private func totalsRow(_ m: NutritionMacros) -> some View {
        let cells: [(String, String)] = [
            ("kcal", "\(Int(m.kcal.rounded()))"), ("protein", Self.g(m.proteinG)), ("carbs", Self.g(m.carbsG)),
            ("fibre", Self.g(m.fiberG)), ("sugar", Self.g(m.sugarG)), ("fat", Self.g(m.fatG)), ("sat fat", Self.g(m.satFatG)),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 8) {
            ForEach(cells, id: \.0) { c in
                VStack(spacing: 2) {
                    Text(c.1).font(StrandFont.headline).monospacedDigit().foregroundStyle(StrandPalette.textPrimary)
                    Text(c.0).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(NoopPanelSurface(cornerRadius: 10))
            }
        }
    }

    static func g(_ v: Double) -> String { v < 10 ? String(format: "%.1f g", v) : "\(Int(v.rounded())) g" }

    // MARK: Actions

    private func run(useOpus: Bool) async {
        working = true
        error = nil
        defer { working = false }
        do {
            estimate = try await NutritionEstimator.estimate(
                coach: coach, text: text, images: photos, useOpus: useOpus,
                previous: estimate, correction: estimate == nil ? nil : (correction.isEmpty ? "Check it again." : correction))
            correction = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        guard let e = estimate else { return }
        let now = Int(Date().timeIntervalSince1970)
        let recipe = NutritionRecipe(
            id: editing?.id ?? UUID().uuidString, name: e.name, serving: e.serving, category: editing?.category,
            macros: e.totals, parts: e.parts, notes: e.notes,
            sourceText: text.isEmpty ? editing?.sourceText : text,
            oneOff: editing?.oneOff ?? oneOff, archived: editing?.archived ?? false,
            createdAt: editing?.createdAt ?? now, updatedAt: now, lastUsedTs: editing?.lastUsedTs)
        await repo.saveNutritionRecipe(recipe)
        onSaved(recipe)
        dismiss()
    }

    /// Photos are sent as JPEG no larger than 1,600 px on the long side.
    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        var out: [Data] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let jpeg = Self.downscaledJPEG(data) {
                out.append(jpeg)
            }
        }
        photos = out
    }

    static func downscaledJPEG(_ data: Data, maxPixel: Int = 1600) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

/// Edit one part's name and seven numbers (and sodium). Returns nil to delete the part.
private struct PartEditor: View {
    @State var part: NutritionRecipePart
    let onDone: (NutritionRecipePart?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $part.name)
                field("kcal", \.kcal)
                field("Protein (g)", \.proteinG)
                field("Carbs (g)", \.carbsG)
                field("Fibre (g)", \.fiberG)
                field("Sugar (g)", \.sugarG)
                field("Fat (g)", \.fatG)
                field("Saturated fat (g)", \.satFatG)
                HStack {
                    Text("Sodium (mg)")
                    Spacer()
                    TextField("unknown", value: $part.macros.sodiumMg, format: .number)
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                }
                Button("Delete part", role: .destructive) { onDone(nil) }
            }
            .navigationTitle("Part")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { onDone(part) } }
            }
        }
        .frame(minWidth: 340, minHeight: 460)
    }

    private func field(_ label: LocalizedStringKey, _ key: WritableKeyPath<NutritionMacros, Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", value: Binding(get: { part.macros[keyPath: key] }, set: { part.macros[keyPath: key] = $0 }),
                      format: .number)
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
        }
    }
}
