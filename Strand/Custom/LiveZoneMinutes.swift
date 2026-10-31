import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopProtocol

// nikhil/custom — the live workout's HR-zone card as a bar chart: one bar per zone, its height the minutes
// spent there so far, growing as the session runs. Replaces the five-tile "which zone am I in" rail.

enum LiveZoneMinutes {
    /// Minutes in zones 1…5 (index 0 = Z1) for a live sample stream. Each reading is credited with the gap
    /// to the next one, capped at Effort's `maxSampleGapMin` so a pause or a dropped link is not counted as
    /// time in whatever zone came before it; the newest reading gets one second. Time below zone 1 is left
    /// out, as on every other zone surface.
    static func minutes(_ samples: [HRSample], zones: HRZoneSet) -> [Double] {
        var out = [Double](repeating: 0, count: 5)
        for (i, s) in samples.enumerated() {
            let gapS = i + 1 < samples.count ? Double(samples[i + 1].ts - s.ts) : 1
            let minutes = min(max(gapS, 0) / 60, StrainScorer.maxSampleGapMin)
            let z = zones.zoneNumber(forBPM: Double(s.bpm))
            if (1...5).contains(z) { out[z - 1] += minutes }
        }
        return out
    }

    /// "12m", or "45s" under a minute, for a bar's label.
    static func label(_ minutes: Double) -> String {
        minutes < 1 ? "\(Int((minutes * 60).rounded()))s" : "\(Int(minutes.rounded()))m"
    }
}

/// Five bars, Z1…Z5, scaled to the largest so far; the zone the wearer is in now is drawn solid, the rest
/// tinted, so "where am I" survives the switch from tiles to bars. In an interval workout each bar also
/// carries an on-pace marker: the minutes the plan expects in that zone by now.
struct LiveZoneBars: View {
    let minutes: [Double]
    let currentZone: Int
    var targets: [Double]? = nil
    private let plotHeight: CGFloat = 96

    var body: some View {
        let top = max(minutes.max() ?? 0, targets?.max() ?? 0, 1.0 / 60)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(1...5, id: \.self) { z in
                let m = minutes[z - 1]
                let color = StrandPalette.hrZoneColor(z)
                let active = z == currentZone
                VStack(spacing: 4) {
                    Text(m > 0 ? LiveZoneMinutes.label(m) : "–")
                        .font(StrandFont.captionNumber).monospacedDigit()
                        .foregroundStyle(m > 0 ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? color : color.opacity(0.55))
                        // A sliver even at zero so an empty zone still reads as a slot on the axis.
                        .frame(height: max(4, plotHeight * CGFloat(m / top)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(active ? color : .clear, lineWidth: 1.5)
                        )
                        // Only an interval workout pins the plot height, so its markers share one scale;
                        // a plain workout keeps the label riding on top of its bar.
                        .frame(height: targets == nil ? nil : plotHeight, alignment: .bottom)
                        .overlay(alignment: .bottom) {
                            if let t = targets?[z - 1], t > 0 { paceMarker(height: plotHeight * CGFloat(t / top)) }
                        }
                    Text("Z\(z)")
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(active ? color : StrandPalette.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(accessibilityText(zone: z, minutes: m)))
            }
        }
        .frame(height: plotHeight + 44, alignment: .bottom)
        .animation(.easeOut(duration: 0.4), value: minutes)
    }

    /// A bar-wide tick at the on-pace height, with a small notch so it reads over a bar of any colour.
    private func paceMarker(height: CGFloat) -> some View {
        Capsule()
            .fill(StrandPalette.textPrimary)
            .frame(height: 3)
            .padding(.horizontal, -3)
            .shadow(color: StrandPalette.surfaceBase.opacity(0.8), radius: 1)
            .offset(y: -max(0, height - 1.5))
    }

    private func accessibilityText(zone z: Int, minutes m: Double) -> String {
        guard let t = targets?[z - 1], t > 0 else { return "Zone \(z), \(LiveZoneMinutes.label(m))" }
        return "Zone \(z), \(LiveZoneMinutes.label(m)), on pace for \(LiveZoneMinutes.label(t))"
    }
}
