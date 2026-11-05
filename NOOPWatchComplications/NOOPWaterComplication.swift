import WidgetKit
import SwiftUI
import StrandDesign

// nikhil/custom — the water complication: today's water against the goal, and what's left (with whether
// that's on the hourly pace). Tapping it opens the watch app on the Water page and logs one glass there
// (`noop-water://log`), then the app closes itself after an undo window (`WatchWaterAutoClose`);
// watch-face complications can't run an action without opening the app.
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
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: WaterEntry

    private var snap: WatchHydrationSnapshot? { entry.snapshot?.current(now: entry.date) }
    private var behind: Bool { (snap?.behindML(now: entry.date) ?? 0) > 0 }
    /// Red when behind the hourly pace for the time of day, green when at or ahead of it.
    private var tint: Color {
        guard snap != nil else { return StrandPalette.textTertiary }
        return behind ? StrandPalette.statusCritical : StrandPalette.statusPositive
    }

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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibility))
    }

    private var bottle: WaterBottle {
        // On tinted faces colour is dropped, so the fill then reads by contrast with the empty part.
        WaterBottle(fraction: snap?.fraction ?? 0, tint: tint, fullColor: renderingMode == .fullColor)
    }

    private var circular: some View {
        bottle.padding(.vertical, 5).widgetAccentable()
    }

    private var corner: some View {
        bottle.padding(2).widgetAccentable()
    }

    private var inline: some View {
        Text("\(Image(systemName: "waterbottle.fill")) \(status)")
    }

    private var rectangular: some View {
        HStack(spacing: 10) {
            bottle.frame(width: 30).widgetAccentable()
            VStack(alignment: .leading, spacing: 2) {
                Text("Water").font(StrandFont.rounded(14, weight: .bold))
                Text(status).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
            }
            Spacer(minLength: 0)
        }
    }

    private var status: String {
        guard let snap else { return String(localized: "Not set up") }
        if snap.remainingML == 0 { return String(localized: "Goal reached") }
        return behind ? String(localized: "Behind") : String(localized: "On pace")
    }

    private var accessibility: String {
        guard let snap else { return String(localized: "Water: not set up") }
        return String(localized: "Water \(Int((snap.fraction * 100).rounded())) percent of goal, \(status). Tap to log a glass.")
    }
}

/// A water bottle that fills from the bottom: the liquid in `tint`, the empty part faint, a thin outline.
struct WaterBottle: View {
    let fraction: Double
    let tint: Color
    let fullColor: Bool

    var body: some View {
        GeometryReader { geo in
            let shape = BottleShape()
            ZStack(alignment: .bottom) {
                shape.fill(tint.opacity(fullColor ? 0.18 : 0.25))
                Rectangle()
                    .fill(fullColor ? tint : Color.white)
                    .frame(height: geo.size.height * min(1, max(0, fraction)))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .mask(shape)
                shape.stroke(fullColor ? tint : Color.white.opacity(0.8), lineWidth: 1.5)
            }
        }
        .aspectRatio(0.5, contentMode: .fit)
    }
}

/// Cap, neck, rounded shoulders and a body with soft bottom corners, in a 1:2 box.
struct BottleShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height, x = r.minX, y = r.minY
        let capW = w * 0.42, neckW = w * 0.36
        let capH = h * 0.09, neckH = h * 0.08, shoulderH = h * 0.12
        let bodyTop = y + capH + neckH + shoulderH
        let corner = w * 0.18
        var p = Path()
        // Cap.
        p.addRoundedRect(in: CGRect(x: x + (w - capW) / 2, y: y, width: capW, height: capH),
                         cornerSize: CGSize(width: w * 0.06, height: w * 0.06))
        // Neck down into the shoulders, the body, and back up.
        let nl = x + (w - neckW) / 2, nr = nl + neckW
        p.move(to: CGPoint(x: nl, y: y + capH))
        p.addLine(to: CGPoint(x: nl, y: y + capH + neckH))
        p.addQuadCurve(to: CGPoint(x: x, y: bodyTop), control: CGPoint(x: x, y: y + capH + neckH))
        p.addLine(to: CGPoint(x: x, y: y + h - corner))
        p.addQuadCurve(to: CGPoint(x: x + corner, y: y + h), control: CGPoint(x: x, y: y + h))
        p.addLine(to: CGPoint(x: x + w - corner, y: y + h))
        p.addQuadCurve(to: CGPoint(x: x + w, y: y + h - corner), control: CGPoint(x: x + w, y: y + h))
        p.addLine(to: CGPoint(x: x + w, y: bodyTop))
        p.addQuadCurve(to: CGPoint(x: nr, y: y + capH + neckH), control: CGPoint(x: x + w, y: y + capH + neckH))
        p.addLine(to: CGPoint(x: nr, y: y + capH))
        p.closeSubpath()
        return p
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
        .description("A water bottle that fills as you drink: green on pace, red behind. Tap to log a glass.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}
