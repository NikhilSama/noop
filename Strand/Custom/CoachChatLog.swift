import Foundation

// nikhil/custom — a permanent, local archive of AI Coach chats, plus a once-a-day upload of each finished
// day to S3.
//
// The Coach keeps ONE conversation and replaces it wholesale (a new day, or "Clear conversation"), so the
// store never holds history. Every persisted snapshot is therefore also merged into a per-day archive file
// here (messages upserted by id, so a streamed reply's growing text simply overwrites, and a mid-day clear
// loses nothing already archived).
//
// Upload target comes from a bundled, git-excluded `CoachChatUpload.local.txt` (under `Strand/AI/`):
//   line 1: the folder URL, e.g. https://<bucket>.s3.<region>.amazonaws.com/noop-coach
//   line 2 (optional): user=<name>
// The folder accepts anonymous PUTs only (no read/list), so no credentials live on the phone. Without the
// file nothing is uploaded; the local archive still accumulates.
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

    static func markdown(_ file: DayFile, user: String) -> String {
        var s = "# NOOP Coach — \(user) — \(file.day)\n"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm"
        for e in file.entries.sorted(by: { $0.order < $1.order }) {
            let who = e.role == "user" ? "You" : "Coach"
            s += "\n## \(who) · \(time.string(from: Date(timeIntervalSince1970: TimeInterval(e.firstSeen))))\n\n\(e.text)\n"
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

    // MARK: - Upload

    private static let uploadedKey = "custom.coachChatLog.uploadedDays"

    private static let config: (folder: URL, user: String)? = {
        guard let url = Bundle.main.url(forResource: "CoachChatUpload.local", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first, let folder = URL(string: first), folder.scheme?.lowercased() == "https"
        else { return nil }
        let user = lines.dropFirst().first { $0.hasPrefix("user=") }.map { String($0.dropFirst(5)) } ?? "user"
        return (folder, user)
    }()

    private static let uploadLock = NSLock()
    nonisolated(unsafe) private static var uploading = false

    /// Upload every finished, not-yet-uploaded day. Safe to call often (strap sync, app foreground): it
    /// does nothing until a day has closed, and each day is uploaded once.
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
        for day in daysToUpload(archived: archived, uploaded: uploaded, today: dayString(now)) {
            guard let file = read(day: day), !file.entries.isEmpty else { uploaded.insert(day); continue }
            let name = objectName(user: config.user, day: day, uploadedAt: now)
            var request = URLRequest(url: config.folder.appendingPathComponent(name), timeoutInterval: 20)
            request.httpMethod = "PUT"
            request.setValue("text/markdown; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(markdown(file, user: config.user).utf8)
            guard let (_, response) = try? await URLSession(configuration: .ephemeral).data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { break }   // retry on a later call
            uploaded.insert(day)
            UserDefaults.standard.set(Array(uploaded), forKey: uploadedKey)
        }
        UserDefaults.standard.set(Array(uploaded), forKey: uploadedKey)
    }
}
