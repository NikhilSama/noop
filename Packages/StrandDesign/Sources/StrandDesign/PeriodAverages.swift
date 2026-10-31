#if !os(watchOS)
import Foundation

/// nikhil/custom: the stepped "average per period" overlay drawn across a `TrendChart`.
///
/// The period is chosen from the span the data covers so a chart carries a handful of segments:
/// weekly up to ~2 months, monthly up to ~6 months, quarterly up to ~2 years, yearly beyond. A span
/// under two weeks gets no overlay (a week chart, an intraday or workout trace). Periods are calendar-
/// aligned and clipped to the data's own first/last dates, so the edge segments never run off the line;
/// a partial period (e.g. the current week) averages what it has.
public enum PeriodAverages {

    public struct Segment: Equatable, Identifiable {
        public var start: Date
        public var end: Date
        public var average: Double
        public var id: Date { start }
    }

    /// The calendar unit a span of `days` is averaged over, or nil when the span is too short.
    static func component(forSpanDays days: Double) -> Calendar.Component? {
        switch days {
        case ..<14: return nil
        case ..<70: return .weekOfYear
        case ..<200: return .month
        case ..<800: return .quarter
        default: return .year
        }
    }

    /// Calendar-aligned period averages over `points` (any order). Empty when the span is too short.
    public static func segments(for points: [TrendPoint], calendar: Calendar = .current) -> [Segment] {
        let sorted = points.sorted { $0.date < $1.date }
        guard let first = sorted.first?.date, let last = sorted.last?.date,
              let component = component(forSpanDays: last.timeIntervalSince(first) / 86_400)
        else { return [] }

        var segments: [Segment] = []
        var index = 0
        while index < sorted.count {
            guard let interval = periodInterval(of: component, containing: sorted[index].date, calendar: calendar)
            else { break }
            var sum = 0.0, count = 0
            while index < sorted.count, sorted[index].date < interval.end {
                sum += sorted[index].value
                count += 1
                index += 1
            }
            segments.append(Segment(start: max(interval.start, first),
                                    end: min(interval.end, last),
                                    average: sum / Double(count)))
        }
        return segments
    }

    /// `Calendar.dateInterval(of: .quarter, …)` is unimplemented on Apple platforms (returns nil), so a
    /// quarter is built from its month: the three-month block starting at month 1, 4, 7 or 10.
    private static func periodInterval(of component: Calendar.Component, containing date: Date,
                                       calendar: Calendar) -> DateInterval? {
        guard component == .quarter else { return calendar.dateInterval(of: component, for: date) }
        guard let month = calendar.dateInterval(of: .month, for: date) else { return nil }
        let monthIndex = calendar.component(.month, from: date) - 1
        guard let start = calendar.date(byAdding: .month, value: -(monthIndex % 3), to: month.start),
              let end = calendar.date(byAdding: .month, value: 3, to: start)
        else { return nil }
        return DateInterval(start: start, end: end)
    }
}
#endif
