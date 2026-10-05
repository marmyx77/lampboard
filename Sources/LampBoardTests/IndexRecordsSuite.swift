import LampBoardCore
import Foundation
import TestKit

/// What the search index keeps of a transcript, and how a search is asked (0.7, M1).
enum IndexRecordsSuite {

    private static func line(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }

    private static let transcript: [String] = [
        line(["type": "user", "uuid": "u1", "timestamp": "2026-10-05T08:00:00.000Z", "cwd": "/home/dev/events",
              "origin": ["kind": "human"], "message": ["role": "user", "content": "Rename the slots endpoint"]]),
        line(["type": "user", "uuid": "m1", "timestamp": "2026-10-05T08:00:01.000Z", "isMeta": true,
              "message": ["role": "user", "content": "<system-reminder>context</system-reminder>"]]),
        line(["type": "assistant", "uuid": "a1", "timestamp": "2026-10-05T08:00:09.000Z",
              "message": ["role": "assistant", "content": [["type": "text", "text": "Renamed to /api/v2/slots."],
                                                           ["type": "tool_use", "name": "Edit", "input": [:]]]]]),
        line(["type": "custom-title", "customTitle": "Slots rename"]),
        line(["type": "user", "uuid": "u2", "timestamp": "2026-10-05T08:05:00.000Z",
              "origin": ["kind": "human"], "message": ["role": "user", "content": "Now the tests"]]),
    ]

    static let suite = TestSuite("What the search index keeps", [

        TestCase("The person's words and Claude's answers, never context or tool calls") { t in
            let read = IndexRecords.read(lines: transcript)
            t.expectEqual(read.messages.map(\.role), ["user", "assistant", "user"])
            t.expectEqual(read.messages.map(\.text), ["Rename the slots endpoint", "Renamed to /api/v2/slots.", "Now the tests"])
        },

        TestCase("The conversation: where, what it is called, when, how many prompts") { t in
            let facts = IndexRecords.read(lines: transcript).facts
            t.expectEqual(facts.cwd, "/home/dev/events")
            t.expectEqual(facts.title, "Slots rename")
            t.expectEqual(facts.prompts, 2)
            t.expect(facts.firstAt != nil && facts.lastAt != nil && facts.firstAt! < facts.lastAt!, "first before last")
        },

        TestCase("A later chunk adds to an earlier one, never erases it") { t in
            let first = IndexRecords.read(lines: Array(transcript.prefix(3))).facts
            let second = IndexRecords.read(lines: Array(transcript.suffix(2))).facts.following(first)
            t.expectEqual(second.cwd, "/home/dev/events", "kept")
            t.expectEqual(second.title, "Slots rename", "added")
            t.expectEqual(second.prompts, 2)
            t.expectEqual(second.firstAt, first.firstAt)
            let moved = IndexRecords.read(lines: [line(["type": "user", "uuid": "u7", "timestamp": "2026-10-05T09:00:00.000Z",
                "cwd": "/home/dev/events/sub", "origin": ["kind": "human"], "message": ["role": "user", "content": "x"]])]).facts
            t.expectEqual(moved.following(first).cwd, "/home/dev/events", "where it began, not where it moved to")
        },

        TestCase("A pasted wall of text is kept to its first 4000 characters") { t in
            let long = line(["type": "user", "uuid": "u9", "timestamp": "2026-10-05T09:00:00.000Z", "origin": ["kind": "human"],
                             "message": ["role": "user", "content": String(repeating: "log ", count: 3000)]])
            t.expectEqual(IndexRecords.read(lines: [long]).messages.first?.text.count, IndexRecords.textLimit)
        },

        TestCase("A search is quoted word by word, the last one a prefix") { t in
            t.expectEqual(IndexQuery.fts("aworld-lab deploy"), #""aworld-lab" "deploy"*"#)
            t.expectEqual(IndexQuery.fts(#"say "hi" OR drop"#), #""say" "hi" "OR" "drop"*"#, "operators are words")
            t.expectEqual(IndexQuery.fts("x"), #""x""#, "one letter is not a prefix")
            t.expectNil(IndexQuery.fts("  -- \"\" "), "nothing to search for")
            t.expectEqual(IndexQuery.fts("a b c d e f g h i j")?.components(separatedBy: " ").count, IndexQuery.maxWords)
        },
    ])
}
