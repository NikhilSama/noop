import Foundation

// nikhil/custom — a tiny on-watch diagnostic log (Documents/watch-diag.log), readable from the Mac with
// `devicectl device copy from --domain-type appDataContainer`. Watch-side workout lifecycle only.
enum WatchDiag {
    private static let queue = DispatchQueue(label: "noop.watch-diag")
    private static var url: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("watch-diag.log")
    }

    static func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        queue.async {
            guard let url else { return }
            let data = Data("[\(stamp)] \(line)\n".utf8)
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
                if (try? h.offset()) ?? 0 > 200_000 { try? FileManager.default.removeItem(at: url) }
            } else {
                try? data.write(to: url)
            }
        }
    }
}
