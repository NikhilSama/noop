import WidgetKit
import SwiftUI
import StrandDesign

// nikhil/custom — the food complication: a meter with the plan at its centre. Left of centre is
// undereating against the plan, right is over it (in + planned deficit − out, the Nutrition card's
// headline), coloured by `NutritionBand`: green within ±100 kcal, yellow out to the target's size, red past.
//
// It reads the `WatchNutritionSnapshot` the phone pushed into the shared App Group. The numbers only move
// when the phone sends new ones (a food edit, new active energy); the rectangular face says when that was.
// A snapshot from an earlier day shows as no data.

struct NutritionEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchNutritionSnapshot?
}

struct NutritionProvider: TimelineProvider {
    private static var preview: WatchNutritionSnapshot {
        WatchNutritionSnapshot(day: WatchHydrationSnapshot.dayKey(Date()), offPlanKcal: 40, targetKcal: -300,
                               inKcal: 1428, outKcal: 1688)
    }

    func placeholder(in context: Context) -> NutritionEntry { NutritionEntry(date: Date(), snapshot: Self.preview) }

    func getSnapshot(in context: Context, completion: @escaping (NutritionEntry) -> Void) {
        completion(NutritionEntry(date: Date(), snapshot: context.isPreview ? Self.preview : WatchNutritionSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NutritionEntry>) -> Void) {
        let snap = WatchNutritionSnapshot.load()
        let now = Date()
        // A second entry at midnight blanks yesterday's balance; a push from the phone reloads before then.
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now
        completion(Timeline(entries: [NutritionEntry(date: now, snapshot: snap), NutritionEntry(date: tomorrow, snapshot: snap)],
                            policy: .never))
    }
}

struct NOOPNutritionView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: NutritionEntry

    private var snap: WatchNutritionSnapshot? { entry.snapshot?.current(now: entry.date) }
    private var tint: Color { snap?.band.color ?? StrandPalette.textTertiary }
    private var fullColor: Bool { renderingMode == .fullColor }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryCorner: corner
            case .accessoryInline: inline
            default: rectangular
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibility))
    }

    // MARK: Faces

    private var circular: some View {
        gauge
            .gaugeStyle(.accessoryCircular)
            .widgetAccentable()
    }

    private var corner: some View {
        Text(number)
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .foregroundStyle(fullColor ? tint : .primary)
            .widgetCurvesContent()
            .widgetLabel { gauge.gaugeStyle(.accessoryLinear) }
    }

    private var inline: some View {
        Text("\(Image(systemName: "fork.knife")) \(snap == nil ? String(localized: "No data") : "\(number) kcal")")
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Label("Food", systemImage: "fork.knife").font(StrandFont.rounded(14, weight: .bold))
                Spacer(minLength: 4)
                Text(snap == nil ? "–" : "\(number) kcal")
                    .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(fullColor ? tint : .primary)
            }
            NutritionMeter(value: Double(snap?.offPlanKcal ?? 0), range: snap?.meterRange ?? 600,
                           tint: tint, fullColor: fullColor, empty: snap == nil)
                .frame(height: 8)
                .widgetAccentable()
            Text(footer).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    // MARK: Pieces

    /// A gauge with the plan at its top/centre: the dot runs left when under, right when over.
    private var gauge: some View {
        let range = snap?.meterRange ?? 600
        let value = min(max(Double(snap?.offPlanKcal ?? 0), -range), range)
        return Gauge(value: value, in: -range...range) {
            Image(systemName: "fork.knife")
        } currentValueLabel: {
            Text(snap == nil ? "–" : number).monospacedDigit()
        }
        .tint(Self.gradient(range: range))
    }

    /// Red · yellow · green · yellow · red, the green band ±100 kcal around the centre. The range is twice
    /// the yellow limit, so yellow ends a quarter of the way in from each end.
    static func gradient(range: Double) -> Gradient {
        let g = NutritionBand.onPlanKcal / (2 * range)
        let y = 0.25
        return Gradient(stops: [
            .init(color: StrandPalette.statusCritical, location: 0),
            .init(color: StrandPalette.statusWarning, location: 0.5 - y),
            .init(color: StrandPalette.statusPositive, location: 0.5 - g),
            .init(color: StrandPalette.statusPositive, location: 0.5 + g),
            .init(color: StrandPalette.statusWarning, location: 0.5 + y),
            .init(color: StrandPalette.statusCritical, location: 1),
        ])
    }

    /// "+40", "−250", "+1.2k" (signed, so the direction reads without the meter).
    private var number: String {
        guard let n = snap?.offPlanKcal else { return "–" }
        let sign = n > 0 ? "+" : (n < 0 ? "−" : "")
        let a = abs(n)
        return a >= 1000 ? sign + String(format: "%.1fk", Double(a) / 1000) : sign + "\(a)"
    }

    private var footer: String {
        guard let snap else { return String(localized: "Open NOOP on your iPhone") }
        let time = snap.asOf.formatted(date: .omitted, time: .shortened)
        switch snap.band {
        case .onPlan: return String(localized: "On plan · \(time)")
        case .near: return snap.offPlanKcal > 0 ? String(localized: "A bit over · \(time)") : String(localized: "A bit under · \(time)")
        case .off: return snap.offPlanKcal > 0 ? String(localized: "Over · \(time)") : String(localized: "Under · \(time)")
        }
    }

    private var accessibility: String {
        guard let snap else { return String(localized: "Food: no data today") }
        return String(localized: "Food \(snap.offPlanKcal) kilocalories against the plan")
    }
}

/// A horizontal meter, zero in the middle: faint zones, a centre tick, and a bar from the centre to the
/// value (clamped to the ends) in `tint`.
struct NutritionMeter: View {
    let value: Double
    let range: Double
    let tint: Color
    let fullColor: Bool
    var empty = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let half = w / 2
            let x = half * CGFloat(min(max(value / max(range, 1), -1), 1))
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Capsule().fill((fullColor ? StrandPalette.textTertiary : Color.white).opacity(0.25))
                    // The green band, so "on plan" has a visible target.
                    let band = half * CGFloat(NutritionBand.onPlanKcal / max(range, 1))
                    Rectangle().fill((fullColor ? StrandPalette.statusPositive : Color.white).opacity(0.3))
                        .frame(width: band * 2).offset(x: half - band)
                    if !empty {
                        Capsule().fill(fullColor ? tint : Color.white)
                            .frame(width: max(h, abs(x) + h / 2))
                            .offset(x: x >= 0 ? half - h / 2 : half + x - h / 2)
                    }
                }
                .clipShape(Capsule())
                Rectangle().fill(fullColor ? StrandPalette.textPrimary : Color.white)
                    .frame(width: 2, height: h + 4).offset(x: half - 1)
            }
        }
    }
}

struct NOOPNutritionComplication: Widget {
    let kind = "NOOPNutritionComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NutritionProvider()) { entry in
            NOOPNutritionView(entry: entry)
                .containerBackground(StrandPalette.surfaceBase, for: .widget)
        }
        .configurationDisplayName("Food")
        .description("Today's calories against your plan: centre is on plan, left under, right over.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}
