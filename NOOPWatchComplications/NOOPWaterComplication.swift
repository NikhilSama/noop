import WidgetKit
import SwiftUI
import StrandDesign

// nikhil/custom — the water complication: today's water against the goal, and what's left (with whether
// that's on the hourly pace). Tapping it opens the watch app on the Water page and logs one glass there
// (`noop-water://log`); watch-face complications can't run an action without opening the app.
//
// It reads the `WatchHydrationSnapshot` the phone pushed into the shared App Group. The timeline holds one
// entry per hour boundary for the rest of the day, because the pace moves on the hour even when nothing is
// logged; a log reloads it straight away.

struct WaterEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchHydrationSnapshot?
}

struct WaterProvider: TimelineProvider {
    private static var preview: WatchHydrationSnapshot {
        WatchHydrationSnapshot(day: WatchHydrationSnapshot.dayKey(Date()), totalML: 2100, standardML: 1500,
                               standardApplied: true, goalML: 3750, glassML: 250,
                               windowStartHour: 11, windowEndHour: 21)
    }

    func placeholder(in context: Context) -> WaterEntry { WaterEntry(date: Date(), snapshot: Self.preview) }

    func getSnapshot(in context: Context, completion: @escaping (WaterEntry) -> Void) {
        completion(WaterEntry(date: Date(), snapshot: context.isPreview ? Self.preview : WatchHydrationSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WaterEntry>) -> Void) {
        let snap = WatchHydrationSnapshot.load()
        let now = Date()
        let cal = Calendar.current
        var dates = [now]
        // Each top of the hour until tomorrow's first, so the pace and a new day show without a reload.
        var next = cal.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? now
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now
        while next <= tomorrow {
            dates.append(next)
            next = next.addingTimeInterval(3600)
        }
        completion(Timeline(entries: dates.map { WaterEntry(date: $0, snapshot: snap) }, policy: .after(tomorrow)))
    }
}

struct NOOPWaterView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WaterEntry

    private var snap: WatchHydrationSnapshot? { entry.snapshot?.current(now: entry.date) }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryCorner: corner
            case .accessoryInline: inline
            default: rectangular
            }
        }
        .widgetURL(URL(string: "noop-water://log"))
    }

    private func litres(_ ml: Int) -> String { String(format: "%.1f", Double(ml) / 1000) }
    private var behind: Int { snap?.behindML(now: entry.date) ?? 0 }

    private var circular: some View {
        Gauge(value: snap?.fraction ?? 0) {
            Image(systemName: "drop.fill")
        } currentValueLabel: {
            Text(snap.map { litres($0.totalML) } ?? "–")
                .font(StrandFont.rounded(15, weight: .bold))
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(behind > 0 ? StrandPalette.statusWarning : StrandPalette.accent)
        .widgetAccentable()
    }

    private var corner: some View {
        Image(systemName: "drop.fill")
            .font(.system(size: 20, weight: .semibold))
            .widgetLabel {
                Gauge(value: snap?.fraction ?? 0) {
                    Text("Water")
                } currentValueLabel: {
                    Text(snap.map { litres($0.totalML) } ?? "–")
                }
                .tint(StrandPalette.accent)
            }
    }

    private var inline: some View {
        Group {
            if let snap {
                Text("\(Image(systemName: "drop.fill")) \(litres(snap.totalML))/\(litres(snap.goalML)) L · \(litres(snap.remainingML)) left")
            } else {
                Text("\(Image(systemName: "drop.fill")) Water")
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "drop.fill").foregroundStyle(StrandPalette.accent)
                Text("Water").font(StrandFont.rounded(12, weight: .bold))
                Spacer(minLength: 0)
                if let snap {
                    Text("+\(snap.glassML)").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            if let snap {
                Text("\(litres(snap.totalML)) / \(litres(snap.goalML)) L")
                    .font(StrandFont.rounded(17, weight: .bold)).monospacedDigit()
                Gauge(value: snap.fraction) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(behind > 0 ? StrandPalette.statusWarning : StrandPalette.accent)
                Text(snap.remainingML == 0 ? String(localized: "Goal reached")
                     : behind > 0 ? String(localized: "\(litres(snap.remainingML)) L left · \(behind) ml behind")
                     : String(localized: "\(litres(snap.remainingML)) L left · on pace"))
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                Text("Turn on hydration in NOOP on your iPhone.")
                    .font(.system(size: 11)).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .widgetAccentable()
    }
}

struct NOOPWaterComplication: Widget {
    let kind = "NOOPWaterComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WaterProvider()) { entry in
            NOOPWaterView(entry: entry)
                .containerBackground(StrandPalette.surfaceBase, for: .widget)
        }
        .configurationDisplayName("Water")
        .description("Today's water and what's left. Tap to log a glass.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}
