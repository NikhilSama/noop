import Foundation
import WhoopStore

// nikhil/custom — every tracked day's balance and macros over a span, the one resolver behind the Today
// card (today and the Mon–Sun week) and the Nutrition Trends tab, so the two cannot disagree. A day counts
// when it is the standard or edited; untracked days and days before the first standard are left out.
// Past days use the whole day's active energy; today uses what has been recorded so far.

enum NutritionHistory {
    struct Day: Identifiable, Equatable {
        var day: String
        var balance: NutritionBalance
        var macros: NutritionMacros
        var items: [NutritionItem]
        var isToday: Bool
        var id: String { day }
    }

    struct Loaded {
        var days: [Day]
        var recipes: [String: NutritionRecipe]
        var hasStandard: Bool
    }

    static func load(_ repo: Repository, from: String, to: String, now: Date = Date()) async -> Loaded? {
        guard let store = await repo.nutritionStore() else { return nil }
        let todayKey = Repository.localDayKey(now)
        let recipes = (try? await store.nutritionRecipes()) ?? [:]
        let versions = (try? await store.nutritionStandardVersions()) ?? []
        let days = await repo.nutritionDays(from: from, to: to)
        let metrics = await repo.dailyMetrics(fromDay: from, toDay: to)
        let apple = (try? await store.appleDaily(deviceId: "apple-health", from: from, to: to)) ?? []
        let strapByDay = Dictionary(metrics.map { ($0.day, $0.activeKcalEst) }, uniquingKeysWith: { a, _ in a })
        let appleByDay = Dictionary(apple.map { ($0.day, $0.activeKcal) }, uniquingKeysWith: { a, _ in a })
        let elapsed = now.timeIntervalSince(Calendar.current.startOfDay(for: now)) / 86_400

        let out = days.filter { $0.state == .standard || $0.state == .edited }.map { day -> Day in
            let slots = NutritionResolve.standardSlots(on: day.day, versions: versions) ?? []
            let b = NutritionBalance.make(day: day, standardSlots: slots, recipes: recipes,
                                          appleActiveKcal: appleByDay[day.day] ?? nil,
                                          strapDayKcal: strapByDay[day.day] ?? nil,
                                          dayFraction: day.day == todayKey ? elapsed : 1)
            return Day(day: day.day, balance: b, macros: NutritionMacro.totals(day.items, recipes: recipes),
                       items: day.items, isToday: day.day == todayKey)
        }
        return Loaded(days: out, recipes: recipes, hasStandard: !versions.isEmpty)
    }

    /// The Monday on or before `date` (the vault's ledger week, whatever the locale).
    static func monday(of date: Date, calendar cal: Calendar = .current) -> Date {
        var d = cal.startOfDay(for: date)
        while cal.component(.weekday, from: d) != 2 { d = cal.date(byAdding: .day, value: -1, to: d) ?? d }
        return d
    }

    /// yyyy-MM-dd as local midnight.
    static func date(_ key: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key)
    }

    struct Week: Identifiable, Equatable {
        /// The week's Monday.
        var start: Date
        /// Average balance (in − out) over the week's complete tracked days.
        var averageBalance: Double
        /// Sum of those days' balances.
        var totalBalance: Double
        var days: Int
        var id: Date { start }
    }

    /// Mon–Sun weeks over complete days (today, still filling, is left out), oldest first.
    static func weeks(_ days: [Day], calendar cal: Calendar = .current) -> [Week] {
        var groups: [Date: [Double]] = [:]
        for d in days where !d.isToday {
            guard let date = date(d.day) else { continue }
            groups[monday(of: date, calendar: cal), default: []].append(d.balance.balance)
        }
        return groups.map { start, v in
            Week(start: start, averageBalance: v.reduce(0, +) / Double(v.count), totalBalance: v.reduce(0, +), days: v.count)
        }
        .sorted { $0.start < $1.start }
    }
}
