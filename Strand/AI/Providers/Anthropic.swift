import Foundation
import StrandAnalytics

struct AnthropicClient: AIProviderClient {

    func send(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession
    ) async throws -> String {
        var wire: [[String: Any]] = []
        for m in messages { wire.append(["role": m.role.rawValue, "content": m.content]) }

        // Anthropic: system prompt is a top-level field, not a message role.
        let body: [String: Any] = [
            "model": model,
            // #1074: 900 truncated detailed coaching replies mid-sentence; 4096 lets a full multi-section
            // reply complete (a cap, not a target — the system prompt keeps it short). Matches the others.
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": wire
        ]

        var req = URLRequest(url: AIProvider.anthropic.endpoint)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await performRequest(req, session: session)
        guard let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let text = (first["text"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw emptyReplyError(json)   // #1074: surface the provider's real error if the 200 body has one
        }
        return text
    }

    /// K1: Stream via `stream: true`. Anthropic SSE uses typed events; we extract `content_block_delta`
    /// with `text_delta` via `SseDeltas.anthropicDelta`. Byte-parity pin in
    /// `SseDeltasTests.anthropicReassembleMatchesFullReply`.
    func stream(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession,
        onDelta: (String) -> Void
    ) async throws {
        var wire: [[String: Any]] = []
        for m in messages { wire.append(["role": m.role.rawValue, "content": m.content]) }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": wire,
            "stream": true
        ]

        var req = URLRequest(url: AIProvider.anthropic.endpoint)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        try await performStreamingRequest(req, session: session) { payload in
            if let delta = SseDeltas.anthropicDelta(payload) {
                onDelta(delta)
            }
        }
    }

    func fetchModels(key: String, session: URLSession) async throws -> [String] {
        var req = URLRequest(url: AIProvider.anthropic.modelsEndpoint)
        req.httpMethod = "GET"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        return parseModels(try await performRequest(req, session: session))
    }

    /// Pure: unwrap the `/models` body into ids (Anthropic keeps all non-empty). No network — unit-tested.
    func parseModels(_ json: [String: Any]) -> [String] {
        guard let list = json["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return id
        }
    }
}

// MARK: - nikhil/custom: tool use (web search + on-device data tools)

extension AnthropicClient {
    /// Streams a reply while letting Claude use tools. Server tools (web search) run on Anthropic's side and
    /// arrive as blocks in the same stream; client tools (`tool_use`) are run here via `runTool`, their
    /// results sent back, and the conversation continued, until Claude ends its turn. Only the text is
    /// streamed to `onDelta`; `onStatus` names the tool being used (nil when back to text).
    func streamWithTools(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        tools: [[String: Any]],
        runTool: (String, [String: Any]) async -> (text: String, isError: Bool),
        onStatus: (String?) -> Void,
        session: URLSession,
        onDelta: (String) -> Void
    ) async throws {
        var wire: [[String: Any]] = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        var emittedText = false

        for _ in 0..<8 {
            var turn = AnthropicToolTurn(continuing: emittedText)
            let body: [String: Any] = [
                "model": model,
                "max_tokens": 4096,
                "system": systemPrompt,
                "messages": wire,
                "tools": tools,
                "stream": true,
            ]
            var req = URLRequest(url: AIProvider.anthropic.endpoint)
            req.httpMethod = "POST"
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            try await performStreamingRequest(req, session: session) { payload in
                let out = turn.consume(payload)
                if let status = out.status { onStatus(status.isEmpty ? nil : status) }
                if let chunk = out.text { onDelta(chunk) }
            }
            if let streamError = turn.error { throw AICoachError.network(streamError) }
            if turn.emittedText { emittedText = true }
            let stopReason = turn.stopReason

            // The assistant turn exactly as produced (server tool blocks included), minus empty text blocks.
            let content = turn.content
            guard !content.isEmpty else { break }
            wire.append(["role": "assistant", "content": content])

            switch stopReason {
            case "tool_use":
                var results: [[String: Any]] = []
                for block in content where (block["type"] as? String) == "tool_use" {
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                    let result = await runTool(name, block["input"] as? [String: Any] ?? [:])
                    results.append(["type": "tool_result", "tool_use_id": id,
                                    "content": result.text, "is_error": result.isError])
                }
                guard !results.isEmpty else { onStatus(nil); return }
                wire.append(["role": "user", "content": results])
            case "pause_turn":
                continue   // the server resumes its own tool loop from the trailing server_tool_use
            default:
                onStatus(nil)
                if !emittedText { throw AICoachError.network("The coach returned no text.") }
                return
            }
        }
        onStatus(nil)
    }
}

/// The tool status lines, kept here so the provider file needs nothing from the app layer.
enum CoachToolStatus {
    static func line(for name: String) -> String {
        switch name {
        case "web_search": return "Searching the web…"
        case "get_daily_metrics": return "Checking your daily data…"
        case "get_workouts": return "Checking your workouts…"
        case "get_lift_sessions": return "Checking your lift log…"
        case "get_body_measurements": return "Checking your body measurements…"
        default: return "Looking that up…"
        }
    }
}

/// nikhil/custom: one streamed assistant turn, rebuilt from Anthropic SSE events into the content blocks to
/// send back (text, server_tool_use, web_search_tool_result, tool_use with parsed input). Pure; unit-tested.
struct AnthropicToolTurn {
    private var blocks: [Int: [String: Any]] = [:]
    private var partialJSON: [Int: String] = [:]
    private var startedText = false
    /// Whether earlier turns already streamed text (a new text run then starts with a blank line).
    let continuing: Bool
    private(set) var emittedText = false
    private(set) var stopReason: String?
    private(set) var error: String?

    init(continuing: Bool) { self.continuing = continuing }

    /// Feed one SSE data payload. `text` is what to stream to the reader; `status` is a tool status line
    /// ("" = clear it).
    mutating func consume(_ payload: String) -> (text: String?, status: String?) {
        guard let data = payload.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = event["type"] as? String else { return (nil, nil) }
        let index = event["index"] as? Int ?? 0
        switch type {
        case "content_block_start":
            guard var block = event["content_block"] as? [String: Any] else { return (nil, nil) }
            let blockType = block["type"] as? String
            if blockType == "text" { block.removeValue(forKey: "citations") }
            blocks[index] = block
            if blockType == "server_tool_use" || blockType == "tool_use" {
                return (nil, CoachToolStatus.line(for: block["name"] as? String ?? ""))
            }
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any] else { return (nil, nil) }
            switch delta["type"] as? String {
            case "text_delta":
                guard let text = delta["text"] as? String else { return (nil, nil) }
                let soFar = (blocks[index]?["text"] as? String) ?? ""
                blocks[index]?["text"] = soFar + text
                emittedText = true
                if !startedText {
                    startedText = true
                    return ((continuing ? "\n\n" : "") + text, "")
                }
                return (text, nil)
            case "input_json_delta":
                partialJSON[index, default: ""] += (delta["partial_json"] as? String) ?? ""
            default:
                break   // citations_delta etc.: not kept
            }
        case "content_block_stop":
            if let json = partialJSON[index] {
                let parsed = json.isEmpty ? [:]
                    : ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:])
                blocks[index]?["input"] = parsed
            }
        case "message_delta":
            if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                stopReason = reason
            }
        case "error":
            error = ((event["error"] as? [String: Any])?["message"] as? String) ?? "stream error"
        default:
            break
        }
        return (nil, nil)
    }

    /// The assistant turn as produced, minus empty text blocks (which the API rejects).
    var content: [[String: Any]] {
        blocks.keys.sorted().compactMap { blocks[$0] }.filter {
            !(($0["type"] as? String) == "text" && (($0["text"] as? String) ?? "").isEmpty)
        }
    }
}
