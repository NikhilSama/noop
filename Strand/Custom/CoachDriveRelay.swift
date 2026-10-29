import Foundation

// nikhil/custom — the Google Drive relay behind the Coach's per-user addendum and daily chat-log upload.
// Drive accepts no anonymous writes, so both go through a Google Apps Script web app that runs as its owner
// (source in the git-excluded docs/custom/coach-drive-relay.gs, which holds the folder ids). Only its /exec
// URL is on the phone, in the git-excluded `Strand/AI/*.local.txt` files.
//
// Apps Script cannot set an HTTP status, so every answer is a 200: success is the JSON `{"ok": true, …}`,
// and anything else (a script error page, or a Google sign-in page when the deployment is not open to
// "Anyone") is a failure.
enum CoachDriveRelay {

    struct Reply: Decodable, Equatable {
        var ok: Bool
        var text: String?
    }

    static func reply(_ data: Data) -> Reply? {
        guard let r = try? JSONDecoder().decode(Reply.self, from: data), r.ok else { return nil }
        return r
    }

    static func uploadURL(relay: URL, name: String) -> URL? {
        guard var c = URLComponents(url: relay, resolvingAgainstBaseURL: false) else { return nil }
        c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "name", value: name)]
        return c.url
    }
}
