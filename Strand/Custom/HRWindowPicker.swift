import SwiftUI
import Charts
import StrandDesign

// nikhil/custom — pick a start / end time off the heart-rate trace, for entries made after the fact (adding
// or editing a nap, a sleep, a manual workout) when the exact clock times aren't remembered. Draws the HR
// around the chosen window with the window shaded; dragging on the chart moves whichever edge is nearer,
// snapped to the minute. Writes the same `start` / `end` the sheet's date pickers edit, so the two always
// agree. Zoom and pan buttons widen or shift the view; it recentres when the pickers move the window out of it.
struct HRWindowPicker: View {
    @Binding var start: Date
    @Binding var end: Date
    var tint: Color = StrandPalette.accent
    var startLabel: LocalizedStringKey = "Start"
    var endLabel: LocalizedStringKey = "End"

    @EnvironmentObject private var repo: Repository
    @State private var range: ClosedRange<Date>
    @State private var points: [TrendPoint] = []
    @State private var loading = false
    @State private var dragging: Edge?

    private enum Edge { case start, end }

    /// Shortest window a drag can leave, so the edges never cross.
    private static let minWindow: TimeInterval = 60
    private static let chartHeight: CGFloat = 150

    init(start: Binding<Date>, end: Binding<Date>, tint: Color = StrandPalette.accent,
         startLabel: LocalizedStringKey = "Start", endLabel: LocalizedStringKey = "End") {
        _start = start
        _end = end
        self.tint = tint
        self.startLabel = startLabel
        self.endLabel = endLabel
        _range = State(initialValue: Self.context(start: start.wrappedValue, end: end.wrappedValue))
    }

    /// The view around a window: padded by half its length each side, at least 30 min, never past now.
    static func context(start: Date, end: Date, scale: Double = 1) -> ClosedRange<Date> {
        let span = max(end.timeIntervalSince(start), 60)
        let pad = max(30 * 60, span / 2) * scale
        let now = Date()
        let hi = min(end.addingTimeInterval(pad), now)
        let lo = min(start, hi.addingTimeInterval(-60)).addingTimeInterval(-pad)
        return lo...max(hi, lo.addingTimeInterval(60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack {
                Text("Heart rate").strandOverline()
                Spacer()
                controls
            }
            // The edges as read off the chart (the rules carry no labels: close together they'd collide).
            Text("\(Text(startLabel)) \(Self.clock(start)) · \(Text(endLabel)) \(Self.clock(end)) · \(Self.span(start, end))")
                .font(StrandFont.captionNumber.weight(.semibold)).monospacedDigit()
                .foregroundStyle(tint)
            chart
            HStack {
                Text("Drag on the graph to move the nearer edge.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                Text("\(Self.clock(range.lowerBound))–\(Self.clock(range.upperBound))")
                    .font(StrandFont.captionNumber).monospacedDigit()
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .task(id: rangeKey) { await load() }
        .onChangeCompat(of: start) { _ in recentreIfNeeded() }
        .onChangeCompat(of: end) { _ in recentreIfNeeded() }
    }

    // MARK: Chart

    private var chart: some View {
        Chart {
            RectangleMark(xStart: .value("Start", clampedStart), xEnd: .value("End", clampedEnd))
                .foregroundStyle(tint.opacity(0.16))
            ForEach(points, id: \.date) { p in
                LineMark(x: .value("Time", p.date), y: .value("BPM", p.value))
                    .foregroundStyle(StrandPalette.textPrimary.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
            edgeRule(start, active: dragging == .start)
            edgeRule(end, active: dragging == .end)
        }
        .chartXScale(domain: range)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline)
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline)
                AxisValueLabel().font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(dragGesture(proxy: proxy, geo: geo))
            }
        }
        .frame(height: Self.chartHeight)
        .overlay {
            if points.isEmpty {
                Text(loading ? "Loading heart rate…" : "No heart rate recorded here")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Heart rate from \(Self.clock(range.lowerBound)) to \(Self.clock(range.upperBound)), selected \(Self.clock(start)) to \(Self.clock(end))"))
    }

    @ChartContentBuilder
    private func edgeRule(_ date: Date, active: Bool) -> some ChartContent {
        if range.contains(date) {
            RuleMark(x: .value("Edge", date))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: active ? 3 : 2))
        }
    }

    private var clampedStart: Date { min(max(start, range.lowerBound), range.upperBound) }
    private var clampedEnd: Date { min(max(end, range.lowerBound), range.upperBound) }

    private var yDomain: ClosedRange<Double> {
        let v = points.map(\.value)
        guard let lo = v.min(), let hi = v.max() else { return 40...140 }
        return (floor((lo - 5) / 10) * 10)...(ceil((hi + 5) / 10) * 10)
    }

    private func dragGesture(proxy: ChartProxy, geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let plot = geo[proxy.plotAreaFrame]   // macOS 13 API (plotFrame is 14+)
                let x = value.location.x - plot.origin.x
                guard let raw: Date = proxy.value(atX: min(max(x, 0), plot.width)) else { return }
                let t = Self.snapToMinute(raw)
                if dragging == nil {
                    dragging = abs(t.timeIntervalSince(start)) <= abs(t.timeIntervalSince(end)) ? .start : .end
                }
                switch dragging {
                case .start: start = min(t, end.addingTimeInterval(-Self.minWindow))
                case .end: end = min(max(t, start.addingTimeInterval(Self.minWindow)), Date())
                case nil: break
                }
            }
            .onEnded { _ in dragging = nil }
    }

    // MARK: Zoom / pan

    private var controls: some View {
        HStack(spacing: NoopMetrics.space1) {
            iconButton("chevron.left", label: "Earlier") { shift(-1) }
            iconButton("minus.magnifyingglass", label: "Zoom out") { zoom(2) }
            iconButton("plus.magnifyingglass", label: "Zoom in") { zoom(0.5) }
            iconButton("chevron.right", label: "Later") { shift(1) }
                .disabled(range.upperBound >= Date().addingTimeInterval(-30))
        }
    }

    private func iconButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(StrandFont.footnote.weight(.semibold))
                .frame(width: 30, height: 28)
                .foregroundStyle(StrandPalette.textSecondary)
                .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func zoom(_ factor: Double) {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        let newSpan = min(max(span * factor, 20 * 60), 24 * 3600)
        let mid = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
        setRange(center: mid, span: newSpan)
    }

    private func shift(_ direction: Double) {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        let mid = range.lowerBound.addingTimeInterval(span / 2 + direction * span / 2)
        setRange(center: mid, span: span)
    }

    private func setRange(center: Date, span: TimeInterval) {
        let now = Date()
        let hi = min(center.addingTimeInterval(span / 2), now)
        range = hi.addingTimeInterval(-span)...hi
    }

    /// The pickers moved an edge out of view (a new date, a typed time): re-frame around the window.
    private func recentreIfNeeded() {
        guard dragging == nil else { return }
        if !range.contains(start) || !range.contains(end) {
            range = Self.context(start: start, end: end)
        }
    }

    // MARK: Data

    private var rangeKey: String {
        "\(Int(range.lowerBound.timeIntervalSince1970) / 60)-\(Int(range.upperBound.timeIntervalSince1970) / 60)"
    }

    private func load() async {
        loading = true
        // Debounce a burst of zoom / pan taps into one read.
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard !Task.isCancelled else { return }
        let series = await repo.timelineSeries(metric: .hr,
                                               from: Int(range.lowerBound.timeIntervalSince1970),
                                               to: Int(range.upperBound.timeIntervalSince1970),
                                               targetPoints: 360)
        guard !Task.isCancelled else { return }
        points = series.points.filter { $0.value > 0 }
        loading = false
    }

    static func snapToMinute(_ d: Date) -> Date {
        Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 60).rounded() * 60)
    }

    static func span(_ a: Date, _ b: Date) -> String {
        let m = max(0, Int((b.timeIntervalSince(a) / 60).rounded()))
        return m < 60 ? String(localized: "\(m)m") : String(localized: "\(m / 60)h \(m % 60)m")
    }

    static func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
}
