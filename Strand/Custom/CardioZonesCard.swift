import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign
import WhoopStore

// nikhil/custom — the Trends screen's cardio zones card: this week's minutes in each HR zone against its
// weekly target band, the last N weeks as stacked bars by zone, and how many complete weeks landed each
// zone on target. The gear opens the targets (and whether strength sessions count). See `CardioZones`.
struct CardioZonesCard: View {
    /// How many Mon–Sun weeks the chart covers, this one included.
    let weekCount: Int
    @EnvironmentObject private var repo: Repository
    @StateObject private var profile = ProfileStore()
    @State private var weeks: [CardioZones.Week] = []
    @State private var loaded = false
    @State private var editing = false
    @State private var revision = 0

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                header
                if let current = weeks.last {
                    ForEach(1...5, id: \.self) { zoneRow($0, minutes: current.minutes[$0 - 1]) }
                    if weeks.count > 1 { chart }
                    onTargetLines
                } else if loaded {
                    Text("No workouts yet.").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(CardioZones.includeStrength
                     ? "From all workouts. Zones from Profile; a workout's own imported split is used when it has one."
                     : "From workouts, strength sessions left out. Zones from Profile; a workout's own imported split is used when it has one.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: "\(weekCount)-\(repo.refreshSeq)-\(revision)") { await reload() }
        .sheet(isPresented: $editing) {
            CardioZoneTargetsSheet(zones: profile.hrZoneSet) { revision += 1 }
        }
    }

    private func reload() async {
        let rows = await repo.workoutRows(days: weekCount * 7 + 7)
        let zoneSet = profile.hrZoneSet
        weeks = await CardioZones.weeks(rows, count: weekCount, includeStrength: CardioZones.includeStrength) { row in
            await repo.cardioZoneMinutes(row, zoneSet: zoneSet)
        }
        loaded = true
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cardio zones").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                if let w = weeks.last {
                    Text("This week · \(w.sessions) sessions · \(Int(w.total.rounded())) min")
                        .font(StrandFont.caption).monospacedDigit().foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer()
            Button { editing = true } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.plain).foregroundStyle(StrandPalette.accent)
                .accessibilityLabel(Text("Zone targets"))
        }
    }

    private func zoneRow(_ z: Int, minutes: Double) -> some View {
        let target = CardioZones.target(z)
        let status = CardioZones.status(minutes, target)
        let zone = profile.hrZoneSet.zones[z - 1]
        let top = max(minutes, Double(target?.high ?? 0), Double(target?.low ?? 0), 10) * 1.15
        let color = StrandPalette.hrZoneColor(z)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Zone \(z)").font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                Text(z == 5 ? "\(Int(zone.lower.rounded()))+ bpm" : "\(Int(zone.lower.rounded()))–\(Int(zone.upper.rounded()) - 1) bpm")
                    .font(StrandFont.caption).monospacedDigit().foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                Text("\(Int(minutes.rounded())) min").font(StrandFont.subhead).monospacedDigit()
                    .foregroundStyle(statusColor(status))
                Text(target.map { Self.targetText($0) } ?? String(localized: "no target"))
                    .font(StrandFont.caption).monospacedDigit().foregroundStyle(StrandPalette.textTertiary)
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.textTertiary.opacity(0.12))
                    if let t = target, t.high > 0 {
                        // The target band, so "where should this be" reads without the numbers.
                        Rectangle().fill(StrandPalette.statusPositive.opacity(0.18))
                            .frame(width: max(2, w * Double(t.high - t.low) / top))
                            .offset(x: w * Double(t.low) / top)
                    }
                    Capsule().fill(color).frame(width: minutes > 0 ? max(6, w * minutes / top) : 0)
                    if let t = target, t.low > 0 {
                        Rectangle().fill(StrandPalette.textPrimary).frame(width: 2, height: 14)
                            .offset(x: min(w - 2, w * Double(t.low) / top))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
        }
    }

    static func targetText(_ t: CardioZones.Target) -> String {
        if t.high == 0 { return String(localized: "aim 0") }
        if t.low == 0 { return String(localized: "max \(t.high)") }
        return t.low == t.high ? String(localized: "aim \(t.low)") : String(localized: "aim \(t.low)–\(t.high)")
    }

    private func statusColor(_ s: CardioZones.Status) -> Color {
        switch s {
        case .none, .short: return StrandPalette.textPrimary
        case .good: return StrandPalette.statusPositive
        case .near: return StrandPalette.statusWarning
        case .over: return StrandPalette.statusCritical
        }
    }

    private var chart: some View {
        let names = (1...5).map { "Z\($0)" }
        return Chart {
            ForEach(weeks) { w in
                ForEach(1...5, id: \.self) { z in
                    BarMark(x: .value("Week", w.start, unit: .weekOfYear), y: .value("Minutes", w.minutes[z - 1]))
                        .foregroundStyle(by: .value("Zone", "Z\(z)"))
                }
            }
            if let t = CardioZones.target(2), t.low > 0 {
                RuleMark(y: .value("Zone 2 target", t.low))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("Z2 target \(t.low)").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
            }
        }
        .chartForegroundStyleScale(domain: names, range: (1...5).map { StrandPalette.hrZoneColor($0) })
        .chartXAxis {
            AxisMarks(values: .stride(by: .weekOfYear, count: weekCount > 14 ? 4 : (weekCount > 6 ? 2 : 1))) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.textTertiary.opacity(0.15))
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .frame(height: 180)
    }

    /// "Zone 2 on target 4 of 11 weeks", over complete weeks (this one is still going).
    @ViewBuilder private var onTargetLines: some View {
        let done = weeks.dropLast()
        if !done.isEmpty {
            let lines = (1...5).compactMap { z -> String? in
                guard let t = CardioZones.target(z) else { return nil }
                let hit = done.filter { CardioZones.status($0.minutes[z - 1], t) == .good }.count
                return String(localized: "Z\(z) \(hit)/\(done.count)")
            }
            if !lines.isEmpty {
                Text(String(localized: "Weeks on target: ") + lines.joined(separator: " · "))
                    .font(StrandFont.caption).monospacedDigit().foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The weekly target band for each zone (or none), and whether strength sessions count.
struct CardioZoneTargetsSheet: View {
    let zones: HRZoneSet
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var targets: [CardioZones.Target?] = (1...5).map { CardioZones.target($0) }
    @State private var includeStrength = CardioZones.includeStrength

    var body: some View {
        NavigationStack {
            Form {
                ForEach(1...5, id: \.self) { z in
                    Section {
                        Toggle("Weekly target", isOn: Binding(
                            get: { targets[z - 1] != nil },
                            set: { targets[z - 1] = $0 ? (targets[z - 1] ?? CardioZones.defaults[z - 1] ?? .init(low: 30, high: 60)) : nil }))
                        if let t = targets[z - 1] {
                            Stepper(value: Binding(get: { t.low }, set: { v in
                                targets[z - 1] = .init(low: v, high: max(v, t.high)) }),
                                    in: CardioZones.minutesRange, step: 5) {
                                row("At least", "\(t.low) min")
                            }
                            Stepper(value: Binding(get: { t.high }, set: { v in
                                targets[z - 1] = .init(low: min(t.low, v), high: v) }),
                                    in: CardioZones.minutesRange, step: 5) {
                                row("At most", "\(t.high) min")
                            }
                        }
                    } header: {
                        let zone = zones.zones[z - 1]
                        Text(z == 5 ? "Zone 5 · \(Int(zone.lower.rounded()))+ bpm"
                                    : "Zone \(z) · \(Int(zone.lower.rounded()))–\(Int(zone.upper.rounded()) - 1) bpm")
                    }
                }
                Section {
                    Toggle("Count strength sessions", isOn: $includeStrength)
                    Button("Reset to defaults") {
                        targets = CardioZones.defaults
                        includeStrength = false
                    }
                } footer: {
                    Text("Minutes per Monday–Sunday week. Zone edges come from Profile → heart-rate zones.")
                }
            }
            .navigationTitle("Zone targets")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        for z in 1...5 { CardioZones.save(z, targets[z - 1]) }
                        UserDefaults.standard.set(includeStrength, forKey: CardioZones.includeStrengthKey)
                        onSave()
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 520)
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).monospacedDigit().foregroundStyle(StrandPalette.textSecondary) }
    }
}
