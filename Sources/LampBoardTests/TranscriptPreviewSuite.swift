import LampBoardCore
import Foundation
import TestKit

/// The last thing a transcript says, as a row's second line reads it.
enum TranscriptPreviewSuite {

    private static func record(_ text: String, human: Bool) -> String {
        var object: [String: Any] = [
            "type": human ? "user" : "assistant",
            "uuid": UUID().uuidString,
            "timestamp": "2026-08-01T10:00:00.000Z",
            "sessionId": "s1",
        ]
        if human {
            object["origin"] = ["kind": "human"]
            object["message"] = ["role": "user", "content": text]
        } else {
            object["message"] = [
                "role": "assistant", "content": [["type": "text", "text": text]],
            ]
        }
        return String(
            decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self
        )
    }

    private static func toolCall() -> String {
        let object: [String: Any] = [
            "type": "assistant",
            "uuid": UUID().uuidString,
            "timestamp": "2026-08-01T10:00:00.000Z",
            "sessionId": "s1",
            "message": [
                "role": "assistant",
                "content": [["type": "tool_use", "name": "Read", "id": "t", "input": [:]]],
            ],
        ]
        return String(
            decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self
        )
    }

    static let suite = TestSuite("Transcript preview", [

        // The defining property: a slice from the middle of a file starts on half
        // a record, and half a JSON object must be dropped rather than repaired.
        TestCase("The first, partial line of a slice is discarded") { t in
            let chunk = "id\":\"broken\",\"type\":\"user\"}\n" + record("real answer", human: false)
            let spoken = TranscriptTail.lastSpoken(inTailChunk: chunk)
            t.expectEqual(spoken?.text, "real answer", "text")
        },

        TestCase("Read from the start, nothing is discarded") { t in
            let chunk = record("the only line", human: false)
            let spoken = TranscriptTail.lastSpoken(inTailChunk: chunk, isWholeFile: true)
            t.expectEqual(spoken?.text, "the only line", "text")
        },

        TestCase("It finds the last thing said, not the last record") { t in
            let chunk = [
                "", record("older", human: false), record("newer", human: true),
                toolCall(), toolCall(),
            ].joined(separator: "\n")
            let spoken = TranscriptTail.lastSpoken(inTailChunk: chunk)
            t.expectEqual(spoken?.text, "newer", "tool calls are not speech")
            t.expectEqual(spoken?.kind, .human, "kind")
        },

        // The tail of a working session is a wall of tool calls. Saying so lets
        // the caller widen the slice instead of showing a fragment.
        TestCase("A slice with nothing said returns nothing") { t in
            let chunk = ["", toolCall(), toolCall()].joined(separator: "\n")
            t.expectNil(TranscriptTail.lastSpoken(inTailChunk: chunk), "must report emptiness")
        },

        TestCase("Rubbish in the slice is survivable") { t in
            let chunk = ["", "not json at all", "{\"half\": ", record("fine", human: false)]
                .joined(separator: "\n")
            t.expectEqual(TranscriptTail.lastSpoken(inTailChunk: chunk)?.text, "fine", "text")
        },
    ])
}
