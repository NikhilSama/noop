import Foundation

// nikhil/custom — a permanent, local archive of AI Coach chats, uploaded to a Google Drive folder twice
// a day: today's chat so far once it is past 4 pm, and each finished day in full once it has closed.
//
// The Coach keeps ONE conversation and replaces it wholesale (a new day, or "Clear conversation"), so the
// store never holds history. Every persisted snapshot is therefore also merged into a per-day archive file
// here (messages upserted by id, so a streamed reply's growing text simply overwrites, and a mid-day clear
// loses nothing already archived).
//
// Upload target comes from a bundled, git-excluded `CoachChatUpload.local.txt` (under `Strand/AI/`):
//   line 1: the Drive relay's Apps Script /exec URL (see `CoachDriveRelay`)
//   line 2 (optional): user=<name>, used only when the NOOP profile has no name
// No Google credentials live on the phone. Without the file nothing is uploaded; the local archive still
// accumulates.
enum CoachChatLog {

    struct Entry: Codable, Equatable {
        var id: String
        var role: String
        var text: String
        var firstSeen: Int
        var order: Int
    }

    struct DayFile: Codable, Equatable {
        var day: String            // yyyy-MM-dd, local
        var entries: [Entry]
    }

    // MARK: - Pure

    /// Upsert a snapshot into a day's entries: known ids take the new text, new ids append in snapshot order.
    static func merge(_ existing: [Entry], snapshot: [(id: String, role: String, text: String)], now: Int) -> [Entry] {
        var out = existing
        var index = Dictionary(uniqueKeysWithValues: out.enumerated().map { ($1.id, $0) })
        for m in snapshot {
            if let i = index[m.id] {
                out[i].text = m.text
            } else {
                index[m.id] = out.count
                out.append(Entry(id: m.id, role: m.role, text: m.text, firstSeen: now, order: out.count))
            }
        }
        return out
    }

    /// The role of the divider "Clear conversation" leaves in the day's archive.
    static let breakRole = "break"

    /// Mark that a new conversation starts here. Nothing to divide on an empty day, and a second clear
    /// with nothing said in between adds no second divider.
    static func appendBreak(_ existing: [Entry], now: Int) -> [Entry] {
        guard let last = existing.last, last.role != breakRole else { return existing }
        return existing + [Entry(id: "break-\(now)-\(existing.count)", role: breakRole, text: "",
                                 firstSeen: now, order: existing.count)]
    }

    static func markdown(_ file: DayFile, user: String) -> String {
        var s = "# XYLO Coach — \(user) — \(file.day)\n"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm"
        for e in file.entries.sorted(by: { $0.order < $1.order }) {
            let at = time.string(from: Date(timeIntervalSince1970: TimeInterval(e.firstSeen)))
            if e.role == breakRole {
                s += "\n---\n\n*New conversation · \(at)*\n"
                continue
            }
            let who = e.role == "user" ? "You" : "Coach"
            s += "\n## \(who) · \(at)\n\n\(e.text)\n"
        }
        return s
    }

    /// `<user>-<HHmm of upload>-<dd>-<MM>-<yyyy>.md`, the date being the chat's day.
    static func objectName(user: String, day: String, uploadedAt: Date, calendar: Calendar = .current) -> String {
        let parts = day.split(separator: "-")
        let c = calendar.dateComponents([.hour, .minute], from: uploadedAt)
        let hhmm = String(format: "%02d%02d", c.hour ?? 0, c.minute ?? 0)
        let dmy = parts.count == 3 ? "\(parts[2])-\(parts[1])-\(parts[0])" : day
        let safeUser = user.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return "\(safeUser.isEmpty ? "user" : safeUser)-\(hhmm)-\(dmy).md"
    }

    /// Days that are finished (before today) and not yet uploaded, oldest first.
    static func daysToUpload(archived: [String], uploaded: Set<String>, today: String) -> [String] {
        archived.filter { $0 < today && !uploaded.contains($0) }.sorted()
    }

    /// Hour (local) after which today's chat so far is uploaded once, ahead of the full day after midnight.
    static let afternoonUploadHour = 16

    /// Today's day string when the afternoon upload is due: past `afternoonUploadHour` and not yet done today.
    static func afternoonUploadDay(now: Date, lastDone: String?, calendar: Calendar = .current) -> String? {
        let today = dayString(now, calendar: calendar)
        guard calendar.component(.hour, from: now) >= afternoonUploadHour, lastDone != today else { return nil }
        return today
    }

    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Archive

    private static let queue = DispatchQueue(label: "noop.coach-chat-log")

    private static var directory: URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("CoachChatLog", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(day: String) -> URL? { directory?.appendingPathComponent("\(day).json") }

    private static func read(day: String) -> DayFile? {
        guard let url = fileURL(day: day), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DayFile.self, from: data)
    }

    /// Merge the Coach's current transcript into today's archive file. Cheap; runs off the main thread.
    static func record(_ snapshot: [(id: String, role: String, text: String)], at date: Date = Date()) {
        guard !snapshot.isEmpty else { return }
        let day = dayString(date), now = Int(date.timeIntervalSince1970)
        queue.async {
            let existing = read(day: day)?.entries ?? []
            let merged = merge(existing, snapshot: snapshot, now: now)
            guard merged != existing, let url = fileURL(day: day),
                  let data = try? JSONEncoder().encode(DayFile(day: day, entries: merged)) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Called by "Clear conversation": leaves a divider in today's archive so the uploaded day shows
    /// where one conversation ended and the next began. Same serial queue as `record`, so it lands after
    /// any snapshot already queued.
    static func recordBreak(at date: Date = Date()) {
        let day = dayString(date), now = Int(date.timeIntervalSince1970)
        queue.async {
            let existing = read(day: day)?.entries ?? []
            let marked = appendBreak(existing, now: now)
            guard marked != existing, let url = fileURL(day: day),
                  let data = try? JSONEncoder().encode(DayFile(day: day, entries: marked)) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Upload

    // A fresh key for Drive, so days already sent to the old S3 folder are uploaded again.
    private static let uploadedKey = "custom.coachChatLog.uploadedDays.drive"
    /// The last day whose afternoon (partial) upload went through.
    private static let afternoonKey = "custom.coachChatLog.afternoonDay.drive"

    private static let config: (relay: URL, user: String)? = {
        guard let url = Bundle.main.url(forResource: "CoachChatUpload.local", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first, let relay = URL(string: first), relay.scheme?.lowercased() == "https"
        else { return nil }
        let user = lines.dropFirst().first { $0.hasPrefix("user=") }.map { String($0.dropFirst(5)) } ?? "user"
        return (relay, user)
    }()

    private static let uploadLock = NSLock()
    nonisolated(unsafe) private static var uploading = false

    /// Upload every finished, not-yet-uploaded day, and after 4 pm today's chat so far. Safe to call often
    /// (strap sync, app foreground): each finished day is uploaded once, and the afternoon upload once a day.
    /// The afternoon file does not count as the day's upload, so the full day still goes up after midnight.
    static func uploadIfDue(now: Date = Date()) async {
        guard let config else { return }
        uploadLock.lock()
        if uploading { uploadLock.unlock(); return }
        uploading = true
        uploadLock.unlock()
        defer { uploadLock.lock(); uploading = false; uploadLock.unlock() }

        guard let dir = directory else { return }
        let archived = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
        var uploaded = Set(UserDefaults.standard.stringArray(forKey: uploadedKey) ?? [])
        // The NOOP profile's name; the link file's `user=` only as a fallback for an unnamed profile.
        let user = ProfileStore.currentNameSlug ?? config.user
        for day in daysToUpload(archived: archived, uploaded: uploaded, today: dayString(now)) {
            guard let file = read(day: day), !file.entries.isEmpty else { uploaded.insert(day); continue }
            guard await post(file, user: user, relay: config.relay, now: now) else { break }   // retry later
            uploaded.insert(day)
            UserDefaults.standard.set(Array(uploaded), forKey: uploadedKey)
        }
        UserDefaults.standard.set(Array(uploaded), forKey: uploadedKey)

        let d = UserDefaults.standard
        if let today = afternoonUploadDay(now: now, lastDone: d.string(forKey: afternoonKey)) {
            // A day with no chat yet has nothing to send, and is checked again on the next call.
            if let file = read(day: today), file.entries.contains(where: { $0.role != breakRole }),
               await post(file, user: user, relay: config.relay, now: now) {
                d.set(today, forKey: afternoonKey)
            }
        }
    }

    private static func post(_ file: DayFile, user: String, relay: URL, now: Date) async -> Bool {
        let name = objectName(user: user, day: file.day, uploadedAt: now)
        guard let url = CoachDriveRelay.uploadURL(relay: relay, name: name) else { return false }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(markdown(file, user: ProfileStore.currentName ?? user).utf8)
        // Apps Script answers a POST with a 302 to its output, which URLSession follows as a GET.
        guard let (data, response) = try? await URLSession(configuration: .ephemeral).data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return CoachDriveRelay.reply(data) != nil
    }
}
