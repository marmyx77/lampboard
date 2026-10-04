import LampBoardCore
import Foundation

/// Transcript records made up for LampMaster's suites. Invented projects only.
enum LampMasterFixtures {

    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    static func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    static func stamp(_ minutes: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: at(minutes))
    }

    static func line(_ record: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func prompt(_ text: String, at minutes: Double, cwd: String = "/home/dev/docs-site",
                       entrypoint: String? = nil, branch: String? = nil) -> String {
        var record: [String: Any] = ["type": "user", "timestamp": stamp(minutes), "cwd": cwd, "origin": ["kind": "human"],
                                     "message": ["role": "user", "content": text]]
        record["entrypoint"] = entrypoint
        record["gitBranch"] = branch
        return line(record)
    }

    static func answer(_ text: String, at minutes: Double, model: String = "claude-opus-5-5",
                       context: Int = 50_000, cwd: String = "/home/dev/docs-site") -> String {
        line(["type": "assistant", "timestamp": stamp(minutes), "cwd": cwd,
              "message": ["role": "assistant", "model": model,
                          "content": [["type": "text", "text": text]],
                          "usage": ["input_tokens": 10, "cache_read_input_tokens": context - 10,
                                    "cache_creation_input_tokens": 0]]])
    }

    static func call(_ id: String, tool: String, input: [String: Any], at minutes: Double,
                     cwd: String = "/home/dev/docs-site") -> String {
        line(["type": "assistant", "timestamp": stamp(minutes), "cwd": cwd,
              "message": ["role": "assistant", "model": "claude-opus-5-5",
                          "content": [["type": "tool_use", "id": id, "name": tool, "input": input]]]])
    }

    static func result(_ id: String, error: Bool = false, text: String = "ok", at minutes: Double,
                       cwd: String = "/home/dev/docs-site") -> String {
        line(["type": "user", "timestamp": stamp(minutes), "cwd": cwd,
              "message": ["role": "user",
                          "content": [["type": "tool_result", "tool_use_id": id, "is_error": error,
                                       "content": text]]]])
    }

    static func card(_ id: String, _ chunks: [String]) -> SessionCard {
        var reader = SessionCardReader(sessionId: id)
        reader.consume(chunks.joined())
        return reader.card
    }
}
