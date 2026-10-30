import Foundation
import WhoopStore

// nikhil/custom — tools the AI Coach can use mid-answer (Anthropic provider): Claude's server-side web
// search, plus on-device data tools that read NOOP's own store, so the coach can look up the history it
// needs instead of seeing only the fixed summary. Tool results are compact text tables to save tokens.
@MainActor
enum CoachTools {

    static let enabledKey = "custom.coach.toolsEnabled"
    /// On unless switched off (UserDefaults bool, default true).
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// Most days a daily-metrics call may return (the dashboard cache holds about this much).
    static let maxDays = 120

    /// The Anthropic `tools` array: web search (newest variant the model supports) + the data tools.
    static func anthropicTools(model: String) -> [[String: Any]] {
        let dynamic = ["4-6", "4-7", "4-8", "opus-5", "sonnet-5", "fable", "mythos", "haiku-5"].contains { model.contains($0) }
        var tools: [[String: Any]] = [[
            "type": dynamic ? "web_search_20260209" : "web_search_20250305",
            "name": "web_search",
            "max_uses": 5,
        ]]
        tools += dataTools
        return tools
    }

    private static func dateRangeSchema(extra: [String: Any] = [:], required: [String] = ["start_date", "end_date"]) -> [String: Any] {
        var props: [String: Any] = [
            "start_date": ["type": "string", "description": "First day, YYYY-MM-DD (local)."],
            "end_date": ["type": "string", "description": "Last day, YYYY-MM-DD (local), inclusive."],
        ]
        for (k, v) in extra { props[k] = v }
        return ["type": "object", "properties": props, "required": required]
    }

    static let dataTools: [[String: Any]] = [
        [
            "name": "get_daily_metrics",
            "description": "The user's daily scores from their WHOOP strap, one row per day: charge (recovery 0-100), effort (strain 0-100), sleep minutes (total/deep/REM/light), sleep efficiency %, HRV (RMSSD ms), resting HR, respiratory rate, SpO2 %, skin-temp deviation °C, steps, active kcal. Covers roughly the last \(maxDays) days. Use for trends, comparisons and 'how was my X on/since Y' questions.",
            "input_schema": dateRangeSchema(),
        ],
        [
            "name": "get_workouts",
            "description": "The user's workouts (strap-detected, manual, lifting, Apple Watch) in a date range: start time, sport, duration, effort/strain, avg/max HR, kcal, distance.",
            "input_schema": dateRangeSchema(),
        ],
        [
            "name": "get_lift_sessions",
            "description": "The user's Lift Log strength sessions in a date range, with every set: exercise, set number, weight kg, reps, RPE, warm-up flag. Optionally filter to one exercise (case-insensitive substring, e.g. 'squat').",
            "input_schema": dateRangeSchema(extra: ["exercise": ["type": "string", "description": "Optional exercise name filter."]]),
        ],
        [
            "name": "get_body_measurements",
            "description": "Weight (kg) and body-fat % readings from Apple Health over the last N days, with derived fat mass and lean mass where both are known.",
            "input_schema": [
                "type": "object",
                "properties": ["days": ["type": "integer", "description": "How many days back, 1-730."]],
                "required": ["days"],
            ] as [String: Any],
        ],
    ]

    /// Appended to the system prompt when tools are on: today's date (for date ranges) and how to use them.
    static func promptNote(now: Date = Date()) -> String {
        "Today is \(dayFormatter.string(from: now)). You have tools: get_daily_metrics, get_workouts, "
            + "get_lift_sessions and get_body_measurements read the user's own XYLO history; use them whenever a "
            + "question needs more than the summary above (trends, comparisons, specific dates, lift progress). "
            + "web_search finds current research and facts; use it when evidence or up-to-date information "
            + "matters, and name your sources briefly. Don't use tools for simple questions the summary answers."
    }

    // MARK: - Running a data tool

    static func run(name: String, input: [String: Any], repo: Repository) async -> (text: String, isError: Bool) {
        switch name {
        case "get_daily_metrics": return dailyMetrics(input, repo: repo)
        case "get_workouts": return await workouts(input, repo: repo)
        case "get_lift_sessions": return await liftSessions(input, repo: repo)
        case "get_body_measurements": return await body(input, repo: repo)
        default: return ("Unknown tool \(name).", true)
        }
    }

    private static func range(_ input: [String: Any]) -> (String, String)? {
        guard let a = input["start_date"] as? String, let b = input["end_date"] as? String,
              a.count == 10, b.count == 10 else { return nil }
        return a <= b ? (a, b) : (b, a)
    }

    private static func f(_ v: Double?, _ digits: Int = 0) -> String {
        guard let v, v.isFinite else { return "-" }
        return String(format: "%.\(digits)f", v)
    }
    private static func i(_ v: Int?) -> String { v.map(String.init) ?? "-" }

    static func dailyMetrics(_ input: [String: Any], repo: Repository) -> (text: String, isError: Bool) {
        guard let (from, to) = range(input) else { return ("start_date and end_date must be YYYY-MM-DD.", true) }
        let rows = repo.days.filter { $0.day >= from && $0.day <= to }.sorted { $0.day < $1.day }
        guard !rows.isEmpty else { return ("No daily data between \(from) and \(to).", false) }
        var out = ["day,charge,effort,sleep_min,deep_min,rem_min,light_min,sleep_eff_pct,hrv_ms,rhr,resp_bpm,spo2_pct,skin_temp_dev_c,steps,active_kcal"]
        for r in rows {
            out.append([r.day, f(r.recovery), f(r.strain), f(r.totalSleepMin), f(r.deepMin), f(r.remMin), f(r.lightMin),
                        f(r.efficiency), f(r.avgHrv, 1), i(r.restingHr), f(r.respRateBpm, 1), f(r.spo2Pct, 1),
                        f(r.skinTempDevC, 2), i(r.steps), f(r.activeKcalEst)].joined(separator: ","))
        }
        return (out.joined(separator: "\n"), false)
    }

    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()
    private static let stampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df
    }()

    private static func tsRange(_ from: String, _ to: String) -> (Int, Int)? {
        guard let a = dayFormatter.date(from: from), let b = dayFormatter.date(from: to) else { return nil }
        return (Int(a.timeIntervalSince1970), Int(b.timeIntervalSince1970) + 86_400)
    }

    private static func stamp(_ ts: Int) -> String { stampFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts))) }

    static func workouts(_ input: [String: Any], repo: Repository) async -> (text: String, isError: Bool) {
        guard let (from, to) = range(input), let (a, b) = tsRange(from, to) else {
            return ("start_date and end_date must be YYYY-MM-DD.", true)
        }
        let rows = await repo.workoutRows().filter { $0.startTs >= a && $0.startTs < b }.sorted { $0.startTs < $1.startTs }
        guard !rows.isEmpty else { return ("No workouts between \(from) and \(to).", false) }
        var out = ["start,sport,source,minutes,effort,avg_hr,max_hr,kcal,distance_km"]
        for w in rows.prefix(300) {
            let minutes = Double(w.endTs - w.startTs) / 60
            out.append([stamp(w.startTs), w.sport, w.source, f(minutes), f(w.strain), i(w.avgHr), i(w.maxHr),
                        f(w.energyKcal), f(w.distanceM.map { $0 / 1000 }, 2)].joined(separator: ","))
        }
        return (out.joined(separator: "\n"), false)
    }

    static func liftSessions(_ input: [String: Any], repo: Repository) async -> (text: String, isError: Bool) {
        guard let (from, to) = range(input), let (a, b) = tsRange(from, to) else {
            return ("start_date and end_date must be YYYY-MM-DD.", true)
        }
        guard let store = await repo.storeHandle(),
              let sessions = try? await store.liftSessions(deviceId: repo.deviceId, fromTs: a, toTs: b) else {
            return ("The lift log could not be read.", true)
        }
        let filter = (input["exercise"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        var out = ["session_start,program,exercise,set,weight_kg,reps,rpe,warmup"]
        for s in sessions.sorted(by: { $0.startTs < $1.startTs }) {
            let sets = (try? await store.liftSets(sessionId: s.id)) ?? []
            for set in sets.sorted(by: { ($0.ord, $0.setIndex) < ($1.ord, $1.setIndex) })
            where filter.isEmpty || set.exercise.lowercased().contains(filter) {
                out.append([stamp(s.startTs), s.programName ?? "-", set.exercise, String(set.setIndex),
                            f(set.weightKg, 1), i(set.reps), f(set.rpe, 1), set.isWarmup ? "y" : "n"].joined(separator: ","))
            }
            if out.count > 1500 { break }
        }
        return out.count == 1 ? ("No lift sets between \(from) and \(to)\(filter.isEmpty ? "" : " for '\(filter)'").", false)
                              : (out.joined(separator: "\n"), false)
    }

    static func body(_ input: [String: Any], repo: Repository) async -> (text: String, isError: Bool) {
        let days = min(730, max(1, (input["days"] as? Int) ?? 90))
        async let w = repo.series(key: "weight", source: "apple-health", days: days)
        async let bf = repo.series(key: "body_fat", source: "apple-health", days: days)
        let weight = await w, bodyFat = await bf
        guard !weight.isEmpty || !bodyFat.isEmpty else { return ("No weight or body-fat readings in the last \(days) days.", false) }
        let comp = Dictionary(BodyComposition.series(weight: weight, bodyFat: bodyFat).map { ($0.day, $0) },
                              uniquingKeysWith: { _, b in b })
        let weightByDay = Dictionary(weight.map { ($0.day, $0.value) }, uniquingKeysWith: { _, b in b })
        let allDays = Set(weightByDay.keys).union(comp.keys).sorted()
        var out = ["day,weight_kg,body_fat_pct,fat_mass_kg,lean_mass_kg"]
        for d in allDays {
            let c = comp[d]
            out.append([d, f(weightByDay[d] ?? c?.weightKg, 1), f(c?.bodyFatPct, 1), f(c?.fatKg, 1), f(c?.leanKg, 1)]
                .joined(separator: ","))
        }
        return (out.joined(separator: "\n"), false)
    }
}
