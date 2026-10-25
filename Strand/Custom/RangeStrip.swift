import SwiftUI
import StrandDesign

// nikhil/custom — a compact "where does today sit in my history" strip, reused by every hero breakdown.
//
// One line, min → max over the selected window: a shaded band for the middle 50% of days (p25–p75),
// a median tick, a mean diamond, and today's dot coloured good/bad against the median for the metric's
// direction. The percentile rides on the right; tapping expands the exact numbers.

/// Summary statistics over one window of daily values.
struct RangeStats: Equatable {
    let sorted: [Double]
    let mean: Double

    init?(_ values: [Double]) {
        let clean = values.filter { $0.isFinite }.sorted()
        guard !clean.isEmpty else { return nil }
        sorted = clean
        mean = clean.reduce(0, +) / Double(clean.count)
    }

    var count: Int { sorted.count }
    var min: Double { sorted.first! }
    var max: Double { sorted.last! }
    var median: Double { quantile(0.5) }
    var p25: Double { quantile(0.25) }
    var p75: Double { quantile(0.75) }

    /// Linear-interpolated quantile (same convention as numpy's default).
    func quantile(_ q: Double) -> Double {
        guard sorted.count > 1 else { return sorted[0] }
        let pos = q * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down)), hi = Swift.min(lo + 1, sorted.count - 1)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - Double(lo))
    }

    /// Percentile rank of `v` in 0…100: share of days below it, counting ties as half.
    func percentile(of v: Double) -> Int {
        let below = sorted.filter { $0 < v }.count
        let equal = sorted.filter { $0 == v }.count
        return Int(((Double(below) + Double(equal) / 2) / Double(sorted.count) * 100).rounded())
    }
}

/// Which side of the median is the good side for a metric.
enum RangeGoodness {
    case higher      // HRV, Charge, sleep duration…
    case lower       // resting HR, respiratory rate
    case nearZero    // skin-temp deviation: closer to your normal is better
    case neutral     // Effort: neither more nor less is "good"
}

struct RangeStrip: View {
    let stats: RangeStats
    let current: Double?
    var goodness: RangeGoodness = .higher
    let format: (Double) -> String
    /// Draws the mean / median / today / typical key under the strip (first strip on a page only).
    var showLegend = false
    /// Narrow-tile layout (Key Metrics grid): full-width bar with min · percentile · max beneath, and no
    /// tap-to-expand, since the enclosing tile is itself a tap target.
    var compact = false

    @State private var expanded = false

    private static let good = StrandPalette.recoveryColor(100)
    private static let bad = StrandPalette.recoveryColor(0)

    private var todayColor: Color {
        guard let v = current else { return StrandPalette.textTertiary }
        switch goodness {
        case .higher:   return v >= stats.median ? Self.good : Self.bad
        case .lower:    return v <= stats.median ? Self.good : Self.bad
        case .nearZero:
            let absMedian = RangeStats(stats.sorted.map(abs))?.median ?? 0
            return abs(v) <= absMedian ? Self.good : Self.bad
        case .neutral:  return StrandPalette.accent
        }
    }

    var body: some View {
        if compact { compactBody } else { fullBody }
    }

    private var compactBody: some View {
        VStack(spacing: 3) {
            bar.frame(height: 14)
            HStack(spacing: 4) {
                Text(format(stats.min))
                Spacer(minLength: 2)
                if let v = current {
                    Text(Self.ordinal(stats.percentile(of: v))).foregroundStyle(todayColor)
                }
                Spacer(minLength: 2)
                Text(format(stats.max))
            }
            .font(StrandFont.captionNumber)
            .foregroundStyle(StrandPalette.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(format(stats.min))
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
                bar
                    .frame(height: 16)
                Text(format(stats.max))
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
                if let v = current {
                    Text(Self.ordinal(stats.percentile(of: v)))
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(todayColor)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minWidth: 34, alignment: .trailing)
                }
            }
            if showLegend { legend }
            if expanded { details }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var bar: some View {
        GeometryReader { geo in
            let w = geo.size.width, midY = geo.size.height / 2
            let x: (Double) -> CGFloat = { v in
                let span = stats.max - stats.min
                let f = span > 0 ? (v - stats.min) / span : 0.5
                return CGFloat(Swift.max(0, Swift.min(1, f))) * w
            }
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(StrandPalette.hairlineStrong)
                    .frame(width: w, height: 3)
                    .position(x: w / 2, y: midY)
                // Typical band: the middle 50% of days.
                let lo = x(stats.p25), hi = x(stats.p75)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(StrandPalette.textSecondary.opacity(0.28))
                    .frame(width: Swift.max(3, hi - lo), height: 9)
                    .position(x: (lo + hi) / 2, y: midY)
                // Median tick.
                Rectangle()
                    .fill(StrandPalette.textPrimary.opacity(0.75))
                    .frame(width: 2, height: 14)
                    .position(x: x(stats.median), y: midY)
                // Mean diamond.
                Rectangle()
                    .fill(StrandPalette.textSecondary)
                    .frame(width: 6, height: 6)
                    .rotationEffect(.degrees(45))
                    .position(x: x(stats.mean), y: midY)
                // Today.
                if let v = current {
                    Circle()
                        .fill(todayColor)
                        .overlay(Circle().stroke(StrandPalette.surfaceBase, lineWidth: 1.5))
                        .frame(width: 11, height: 11)
                        .shadow(color: todayColor.opacity(0.6), radius: 3)
                        .position(x: x(v), y: midY)
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            legendItem(Rectangle().fill(StrandPalette.textSecondary.opacity(0.28)).frame(width: 12, height: 7), "typical 50%")
            legendItem(Rectangle().fill(StrandPalette.textPrimary.opacity(0.75)).frame(width: 2, height: 9), "median")
            legendItem(Rectangle().fill(StrandPalette.textSecondary).frame(width: 5, height: 5).rotationEffect(.degrees(45)), "mean")
            legendItem(Circle().fill(Self.good).frame(width: 7, height: 7), "this day")
            Spacer(minLength: 0)
            Text("tap for numbers")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.top, 2)
    }

    private func legendItem<S: View>(_ swatch: S, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            swatch
            Text(text).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var details: some View {
        Text("Mean \(format(stats.mean)) · Median \(format(stats.median)) · Min \(format(stats.min)) · Max \(format(stats.max)) · Typical \(format(stats.p25))–\(format(stats.p75)) · \(stats.count) days")
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
    }

    private var accessibilityText: String {
        var s = "Range \(format(stats.min)) to \(format(stats.max)), median \(format(stats.median)), mean \(format(stats.mean))"
        if let v = current { s += ", this day \(format(v)), \(Self.ordinal(stats.percentile(of: v))) percentile" }
        return s
    }

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }
}

/// What a Key Metrics tile hands its compact strip: the tile's own displayed value (so the dot and the
/// number above it are one reading), which side is good, and a short unit-less formatter for min/max.
struct TileRange {
    let current: Double?
    var goodness: RangeGoodness = .higher
    let format: (Double) -> String
}
