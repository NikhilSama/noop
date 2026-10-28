import XCTest
@testable import Strand

/// nikhil/custom: the coach's tool-use stream reassembly and its data tools.
@MainActor
final class CustomCoachToolsTests: XCTestCase {

    private func feed(_ turn: inout AnthropicToolTurn, _ events: [String]) -> (text: String, statuses: [String]) {
        var text = "", statuses: [String] = []
        for e in events {
            let out = turn.consume(e)
            if let t = out.text { text += t }
            if let s = out.status { statuses.append(s) }
        }
        return (text, statuses)
    }

    func testWebSearchThenDataToolTurnIsRebuiltForContinuation() throws {
        var turn = AnthropicToolTurn(continuing: false)
        let out = feed(&turn, [
            #"{"type":"message_start","message":{"id":"m1"}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"","citations":null}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Let me check."}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{}}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query\": \"zone 2"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" HRV\"}"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":[{"type":"web_search_result","url":"https://x","title":"X","encrypted_content":"abc"}]}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"toolu_1","name":"get_daily_metrics","input":{}}}"#,
            #"{"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"{\"start_date\":\"2026-10-01\",\"end_date\":\"2026-10-28\"}"}}"#,
            #"{"type":"content_block_stop","index":3}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
            #"{"type":"message_stop"}"#,
        ])
        XCTAssertEqual(out.text, "Let me check.")
        XCTAssertEqual(out.statuses, ["", "Searching the web…", "Checking your daily data…"])
        XCTAssertEqual(turn.stopReason, "tool_use")
        let content = turn.content
        XCTAssertEqual(content.map { $0["type"] as? String }, ["text", "server_tool_use", "web_search_tool_result", "tool_use"])
        XCTAssertNil(content[0]["citations"])
        XCTAssertEqual((content[1]["input"] as? [String: Any])?["query"] as? String, "zone 2 HRV")
        XCTAssertNotNil((content[2]["content"] as? [[String: Any]])?.first?["encrypted_content"])
        XCTAssertEqual((content[3]["input"] as? [String: Any])?["end_date"] as? String, "2026-10-28")
        // The rebuilt turn must serialize for the next request.
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: ["role": "assistant", "content": content]))
    }

    func testContinuationTextStartsWithBlankLineAndEmptyTextIsDropped() {
        var turn = AnthropicToolTurn(continuing: true)
        let out = feed(&turn, [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Your HRV"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" is up."}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
        ])
        XCTAssertEqual(out.text, "\n\nYour HRV is up.")
        XCTAssertEqual(turn.content.count, 1)
        XCTAssertEqual(turn.stopReason, "end_turn")
    }

    func testToolsListUsesDynamicWebSearchOnSonnet46() {
        let tools = CoachTools.anthropicTools(model: "claude-sonnet-4-6")
        XCTAssertEqual(tools.first?["type"] as? String, "web_search_20260209")
        XCTAssertEqual(Set(tools.dropFirst().compactMap { $0["name"] as? String }),
                       ["get_daily_metrics", "get_workouts", "get_lift_sessions", "get_body_measurements"])
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: tools))
    }
}
