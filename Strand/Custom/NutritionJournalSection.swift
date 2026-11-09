import SwiftUI
import StrandDesign
import WhoopStore

// nikhil/custom — "Yesterday's food" under the journal: the day before the journal day (a morning entry
// covers the evening before), its final in/out and result against the target, and the same edit controls
// as the Nutrition screen. Finishing the journal locks that day; a day left alone locks itself once the
// following day has ended (`autoLockNutritionDays`).
struct NutritionJournalSection: View {
    /// The journal's day (yyyy-MM-dd); the food shown is the day before it.
    let journalDay: String
    @EnvironmentObject private var repo: Repository
    @AppStorage(NutritionPrefs.enabledKey) private var enabled = false
    @ObservedObject private var changes = NutritionChanges.shared
    @State private var balance: NutritionBalance?

    var foodDay: String { Repository.dayKeys(offset: -1, from: journalDay) }

    var body: some View {
        if enabled {
            NoopCard(tint: StrandPalette.metricAmber) {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    HStack {
                        Text("Yesterday's food").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        if let b = balance {
                            Text("\(NutritionTodayCard.signed(b.balance)) vs \(NutritionTodayCard.signed(b.targetBalance))\(b.hit ? " ✓" : "")")
                                .font(StrandFont.subhead).monospacedDigit()
                                .foregroundStyle(b.hit ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                        }
                    }
                    if let b = balance {
                        Text("In \(Int(b.inKcal.rounded())) · Out \(Int(b.outKcal.rounded())) (resting \(Int(b.rmrKcal)), digestion \(Int(b.tefKcal.rounded())), active \(Int(b.activeKcal.rounded())))")
                            .font(StrandFont.caption).monospacedDigit().foregroundStyle(StrandPalette.textTertiary)
                    }
                    NutritionDayEditor(mode: .day(foodDay))
                }
            }
            .task(id: "\(changes.seq)-\(foodDay)-\(repo.refreshSeq)") { balance = await repo.nutritionBalance(day: foodDay) }
        }
    }
}

extension Repository {
    /// The key `offset` days from `key` (yyyy-MM-dd).
    nonisolated static func dayKeys(offset: Int, from key: String) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: key), let moved = Calendar(identifier: .gregorian).date(byAdding: .day, value: offset, to: d)
        else { return key }
        return f.string(from: moved)
    }

    /// A finished day's balance (whole-day resting burn and active energy), or nil when it has no data.
    func nutritionBalance(day key: String) async -> NutritionBalance? {
        guard let store = await nutritionStore() else { return nil }
        let day = await nutritionDay(key)
        guard day.state == .standard || day.state == .edited else { return nil }
        let recipes = (try? await store.nutritionRecipes()) ?? [:]
        let slots = await nutritionStandardSlots(on: key)
        let strap = await dailyMetrics(fromDay: key, toDay: key).first?.activeKcalEst
        let apple = (try? await store.appleDaily(deviceId: "apple-health", from: key, to: key))?.first?.activeKcal
        let isToday = key == Repository.localDayKey(Date())
        let elapsed = Date().timeIntervalSince(Calendar.current.startOfDay(for: Date())) / 86_400
        return NutritionBalance.make(day: day, standardSlots: slots, recipes: recipes, appleActiveKcal: apple,
                                     strapDayKcal: strap, dayFraction: isToday ? elapsed : 1)
    }

    /// Lock every day from a week back up to two days ago that has food and no lock yet: a day whose
    /// following day has ended without the journal being finished stands as it is.
    func autoLockNutritionDays(now: Date = Date()) async {
        let today = Repository.localDayKey(now)
        let from = Repository.dayKeys(offset: -8, from: today), to = Repository.dayKeys(offset: -2, from: today)
        for day in await nutritionDays(from: from, to: to)
        where day.lockedAt == nil && (day.state == .standard || day.state == .edited) {
            await lockNutritionDay(day.day)
        }
    }
}
