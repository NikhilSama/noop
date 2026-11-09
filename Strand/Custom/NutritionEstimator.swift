import Foundation
import WhoopStore

// nikhil/custom — turn a description and/or photos of food into a recipe: one structured request to the
// Coach's provider, answered as JSON (name, serving, a parts table with the seven numbers per part, notes on
// what was assumed). Totals are always the sum of the parts, so the table and the totals cannot disagree.

enum NutritionEstimator {
    /// Anthropic models: the estimate's default and the "Re-estimate with Opus" choice.
    static let sonnetModel = "claude-sonnet-5-5"
    static let opusModel = "claude-opus-5-5"

    static let systemPrompt = """
    You estimate nutrition for a food log. The user describes a dish, a recipe, a meal or a packaged food, \
    in text and/or photos (a plate, a recipe card, a nutrition label).

    Reply with ONE JSON object and nothing else:
    {"name": "short dish name", "serving": "what one serving is, e.g. 1 bowl (350 g) or 1 bar (55 g)",
     "parts": [{"name": "ingredient with amount, e.g. 2 whole eggs", "kcal": 0, "proteinG": 0, "carbsG": 0,
                "fiberG": 0, "sugarG": 0, "fatG": 0, "satFatG": 0, "sodiumMg": null}],
     "notes": "one or two lines: what you assumed and what is uncertain"}

    Rules:
    - Numbers are for ONE serving. Split the dish into its main ingredients as parts, with amounts.
    - A visible nutrition label is the source of truth: use its per-serving figures as a single part and \
    say so in notes. Otherwise use standard food-composition values.
    - Never leave a number blank: give a best estimate and name the guess in notes \
    ("assumed 1 tsp oil"). sodiumMg may be null when there is no basis for it.
    - Indian home cooking is common: dal, sabzi, roti, rice, ghee; estimate typical home portions and oil.
    - Plain numbers, no units in values, no ranges.
    """

    struct Estimate: Equatable {
        var name: String
        var serving: String
        var parts: [NutritionRecipePart]
        var notes: String
        var totals: NutritionMacros { NutritionMacros.sum(parts.map(\.macros)) }
    }

    enum Failure: LocalizedError {
        case unreadable
        var errorDescription: String? { "The reply wasn't a recipe estimate. Try again or add more detail." }
    }

    /// Ask for an estimate. `correction` re-asks with the previous estimate and the user's fix.
    @MainActor
    static func estimate(coach: AICoachEngine, text: String, images: [Data], useOpus: Bool,
                         previous: Estimate? = nil, correction: String? = nil) async throws -> Estimate {
        var prompt = text.isEmpty ? "Estimate the food in the photo(s)." : text
        if let previous, let correction, !correction.isEmpty {
            prompt += "\n\nYour previous estimate:\n\(encode(previous))\n\nCorrection from the user: \(correction)\n"
                + "Reply with the corrected full JSON."
        }
        let model: String? = coach.provider == .anthropic ? (useOpus ? opusModel : sonnetModel) : nil
        let reply = try await coach.oneShotVision(systemPrompt: systemPrompt, text: prompt, images: images, model: model)
        guard let estimate = parse(reply) else { throw Failure.unreadable }
        return estimate
    }

    /// The JSON object in a reply (tolerates code fences or a sentence around it).
    static func parse(_ reply: String) -> Estimate? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func num(_ d: [String: Any], _ k: String) -> Double {
            if let n = d[k] as? NSNumber { return n.doubleValue }
            if let s = d[k] as? String, let v = Double(s.trimmingCharacters(in: .whitespaces)) { return v }
            return 0
        }
        let parts = (obj["parts"] as? [[String: Any]] ?? []).map { p in
            NutritionRecipePart(name: (p["name"] as? String) ?? "Part", macros: NutritionMacros(
                kcal: num(p, "kcal"), proteinG: num(p, "proteinG"), carbsG: num(p, "carbsG"), fiberG: num(p, "fiberG"),
                sugarG: num(p, "sugarG"), fatG: num(p, "fatG"), satFatG: num(p, "satFatG"),
                sodiumMg: (p["sodiumMg"] as? NSNumber)?.doubleValue))
        }
        guard !parts.isEmpty else { return nil }
        return Estimate(name: (obj["name"] as? String) ?? "Food", serving: (obj["serving"] as? String) ?? "1 serving",
                        parts: parts, notes: (obj["notes"] as? String) ?? "")
    }

    static func encode(_ e: Estimate) -> String {
        let parts = e.parts.map { p -> [String: Any] in
            var d: [String: Any] = ["name": p.name, "kcal": p.macros.kcal, "proteinG": p.macros.proteinG,
                                    "carbsG": p.macros.carbsG, "fiberG": p.macros.fiberG, "sugarG": p.macros.sugarG,
                                    "fatG": p.macros.fatG, "satFatG": p.macros.satFatG]
            if let s = p.macros.sodiumMg { d["sodiumMg"] = s }
            return d
        }
        let obj: [String: Any] = ["name": e.name, "serving": e.serving, "parts": parts, "notes": e.notes]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// One request with images, in each provider's own shape (the chat clients send text only).
enum NutritionVision {
    static func send(provider: AIProvider, key: String, model: String, systemPrompt: String, text: String,
                     images: [Data], session: URLSession) async throws -> String {
        let b64 = images.map { $0.base64EncodedString() }
        var req: URLRequest
        let body: [String: Any]
        switch provider {
        case .anthropic:
            req = URLRequest(url: AIProvider.anthropic.endpoint)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let content: [[String: Any]] = b64.map {
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0]]
            } + [["type": "text", "text": text]]
            body = ["model": model, "max_tokens": 4096, "system": systemPrompt,
                    "messages": [["role": "user", "content": content]]]
        case .openAI, .custom:
            if provider == .custom { try AIProvider.guardCustomBaseURL() }
            req = URLRequest(url: provider.endpoint)
            if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            let content: [[String: Any]] = [["type": "text", "text": text]] + b64.map {
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\($0)"]]
            }
            body = ["model": model, "messages": [["role": "system", "content": systemPrompt],
                                                 ["role": "user", "content": content]]]
        case .gemini:
            guard let url = URL(string: "\(AIProvider.gemini.endpoint.absoluteString)/\(model):generateContent") else {
                throw AICoachError.network("invalid model id")
            }
            req = URLRequest(url: url)
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            let parts: [[String: Any]] = [["text": text]] + b64.map { ["inline_data": ["mime_type": "image/jpeg", "data": $0]] }
            body = ["system_instruction": ["parts": [["text": systemPrompt]]],
                    "contents": [["role": "user", "parts": parts]],
                    "generationConfig": ["maxOutputTokens": 4096]]
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await performRequest(req, session: session)
        let text: String?
        switch provider {
        case .anthropic:
            text = (json["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        case .openAI, .custom:
            text = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        case .gemini:
            text = (((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"]
                    as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw emptyReplyError(json) }
        return text
    }
}
