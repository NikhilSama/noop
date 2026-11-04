import Foundation
import UserNotifications
import StrandDesign

// nikhil/custom — the hydration plan: a fixed daily goal, a STANDARD amount that is counted automatically
// every day (morning water, coffee), the glass size one tap logs, and the window of hours the rest is paced
// over. Local UserDefaults, like the rest of the hydration tracker's settings.
enum HydrationPlan {
    static let goalOverrideKey = "noop.hydrationGoalOverrideML"   // 0 = the automatic goal
    static let standardKey = "noop.hydrationStandardML"
    static let glassKey = "noop.hydrationGlassML"
    static let windowStartKey = "noop.hydrationWindowStart"
    static let windowEndKey = "noop.hydrationWindowEnd"
    static let remindersKey = "noop.hydrationReminders"
    /// Marks a day whose standard amount has been added (so deleting it for that day sticks).
    static let standardAppliedPrefix = "noop.hydrationStandardApplied."

    static let defaultGlassML = 250
    static let defaultWindowStart = 11
    static let defaultWindowEnd = 21

    private static var defaults: UserDefaults { .standard }
    private static func int(_ key: String, _ fallback: Int) -> Int {
        defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
    }

    static var goalOverrideML: Int { max(0, int(goalOverrideKey, 0)) }
    static var standardML: Int { max(0, int(standardKey, 0)) }
    static var glassML: Int { min(max(int(glassKey, defaultGlassML), 10), 3000) }
    static var windowStartHour: Int {
        HydrationPace.window(startHour: int(windowStartKey, defaultWindowStart),
                             endHour: int(windowEndKey, defaultWindowEnd)).start
    }
    static var windowEndHour: Int {
        HydrationPace.window(startHour: int(windowStartKey, defaultWindowStart),
                             endHour: int(windowEndKey, defaultWindowEnd)).end
    }
    static var remindersOn: Bool { defaults.bool(forKey: remindersKey) }
}

/// Everything that follows a change to the day's water: the hourly reminders are re-planned and the watch
/// gets the new total. Called after every log / edit / delete (via `Repository.noteHydrationChanged`), when
/// the plan changes, and when the app comes to the foreground (a new day).
@MainActor
enum HydrationSync {
    /// Sends the snapshot to the watch (set by the iOS app; nil on macOS).
    static var pushToWatch: ((WatchHydrationSnapshot) -> Void)?
    /// The profile's sex token, for the automatic goal (set by the app at launch).
    static var profileSex: () -> String = { "" }
    private static var pending: Task<Void, Never>?

    /// Coalesces a burst of changes (a log bumps the change signal more than once) into one pass.
    static func changed(_ repo: Repository) {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await run(repo)
        }
    }

    /// One pass now; returns the snapshot it sent.
    @discardableResult
    static func run(_ repo: Repository) async -> WatchHydrationSnapshot? {
        guard UserDefaults.standard.bool(forKey: HydrationStore.enabledKey) else {
            HydrationReminders.clear()
            return nil
        }
        let snap = await repo.hydrationWatchSnapshot(profileSex: profileSex())
        await HydrationReminders.reschedule(snap)
        pushToWatch?(snap)
        return snap
    }
}

/// The hourly pace reminders, as local notifications (an iPhone notification also buzzes the paired watch
/// when the phone is locked). Nothing runs in the background to check the pace: every reminder that the
/// day would still need if nothing more were logged is scheduled up front, and each log re-plans them, so a
/// glass that gets ahead of pace cancels the boundaries it covers.
enum HydrationReminders {
    static let categoryId = "noop.hydration"
    static let logActionId = "noop.hydration.log"
    private static let idPrefix = "noop.hydration.remind."
    /// Days planned ahead, so reminders still come on a day the app hasn't been opened yet.
    private static let daysAhead = 2

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func clear() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { reqs in
            center.removePendingNotificationRequests(withIdentifiers: reqs.map(\.identifier).filter { $0.hasPrefix(idPrefix) })
        }
    }

    static func reschedule(_ snap: WatchHydrationSnapshot, now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        // Banners already on screen for hours that are now covered are cleared too.
        let delivered = await center.deliveredNotifications().map(\.request.identifier).filter { $0.hasPrefix(idPrefix) }
        center.removeDeliveredNotifications(withIdentifiers: delivered)
        guard HydrationPlan.remindersOn, snap.trackedTargetML > 0 else { return }

        center.setNotificationCategories([UNNotificationCategory(
            identifier: categoryId,
            actions: [UNNotificationAction(identifier: logActionId,
                                           title: String(localized: "Log \(snap.glassML) ml"), options: [])],
            intentIdentifiers: [], options: [])])

        let cal = Calendar.current
        let start = snap.windowStartHour, end = snap.windowEndHour
        let perHour = snap.trackedTargetML / max(1, end - start)
        for offset in 0...daysAhead {
            guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now)) else { continue }
            // Today counts what's been logged; a later day starts from nothing tracked.
            let tracked = offset == 0 ? snap.trackedML : 0
            for hour in HydrationPace.dueHours(trackedML: tracked, trackedTargetML: snap.trackedTargetML,
                                               startHour: start, endHour: end) {
                guard let fire = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day), fire > now else { continue }
                let expected = HydrationPace.expectedML(trackedTargetML: snap.trackedTargetML, startHour: start,
                                                        endHour: end, byHour: hour)
                let content = UNMutableNotificationContent()
                content.title = String(localized: "Time for water")
                content.body = offset == 0
                    ? String(localized: "You're \(expected - tracked) ml behind pace. Have a glass?")
                    : String(localized: "About \(perHour) ml an hour keeps you on pace.")
                content.sound = .default
                content.categoryIdentifier = categoryId
                content.threadIdentifier = categoryId
                let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                let id = idPrefix + WatchHydrationSnapshot.dayKey(fire) + ".\(hour)"
                try? await center.add(UNNotificationRequest(
                    identifier: id, content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
            }
        }
    }
}
