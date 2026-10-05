import LampBoardCore
import Foundation
import TestKit

/// `lampboard search` and `lampboard week` against a fake home's transcripts
/// (0.7): the real binary, the system's SQLite, the index written owner-only.
enum SearchE2ESuite {

    static func suite(binaryURL: URL, port: UInt16) -> TestSuite {
        func transcript(_ app: AppUnderTest, folder: String, session: String, _ lines: [[String: Any]]) {
            let dir = app.home.appendingPathComponent(".claude/projects/\(folder)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let text = lines.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
                .map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
            try? text.write(to: dir.appendingPathComponent("\(session).jsonl"), atomically: true, encoding: .utf8)
        }
        let now = ISO8601DateFormatter().string(from: Date())

        return TestSuite("E2E · search", [

            TestCase("the conversations that say the words, with their names; context is not searched") { t in
                let app = AppUnderTest(binaryURL: binaryURL, port: port)
                // No instance: the command answers on its own. A home of its own, gone after.
                try? FileManager.default.removeItem(at: app.home)
                defer { try? FileManager.default.removeItem(at: app.home) }
                transcript(app, folder: "-home-dev-events", session: "aaaaaaaa-0000-4000-8000-000000000001", [
                    ["type": "user", "uuid": "u1", "timestamp": now, "cwd": "/home/dev/events", "origin": ["kind": "human"],
                     "message": ["role": "user", "content": "Rename the slots endpoint to v2"]],
                    ["type": "assistant", "uuid": "a1", "timestamp": now,
                     "message": ["role": "assistant", "content": [["type": "text", "text": "Done: /api/v2/slots."]]]],
                    ["type": "custom-title", "customTitle": "Slots rename"],
                ])
                transcript(app, folder: "-home-dev-api", session: "bbbbbbbb-0000-4000-8000-000000000002", [
                    ["type": "user", "uuid": "m1", "timestamp": now, "isMeta": true,
                     "message": ["role": "user", "content": "slots in a reminder nobody typed"]],
                    ["type": "user", "uuid": "u2", "timestamp": now, "origin": ["kind": "human"],
                     "message": ["role": "user", "content": "Città and caffè"]],
                ])
                let found = app.runCommand(["search", "slots"])
                t.expect(found.output.contains("Slots rename"), "found by its words: \(found.output)")
                t.expect(!found.output.contains("bbbbbbbb"), "a reminder is not the conversation")
                t.expect(app.runCommand(["search", "citta"]).output.contains("bbbbbbbb"), "accents folded")
                t.expect(app.runCommand(["search", "nothing-like-this"]).output.contains("No conversation says that."), "said")
                let mode = ((try? FileManager.default.attributesOfItem(atPath: app.home.appendingPathComponent(".lampboard/index.sqlite").path))?[.posixPermissions] as? NSNumber)?.intValue
                t.expectEqual(mode, 0o600, "owner-only")
            },

            TestCase("lampboard week: the last seven days in a paragraph, an older prompt left out") { t in
                let app = AppUnderTest(binaryURL: binaryURL, port: port)
                try? FileManager.default.removeItem(at: app.home)
                defer { try? FileManager.default.removeItem(at: app.home) }
                let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86_400 * 10))
                transcript(app, folder: "-home-dev-events", session: "aaaaaaaa-0000-4000-8000-000000000001", [
                    ["type": "user", "uuid": "u1", "timestamp": now, "cwd": "/home/dev/events", "origin": ["kind": "human"],
                     "message": ["role": "user", "content": "Rename the slots endpoint"]],
                    ["type": "assistant", "uuid": "a1", "timestamp": now,
                     "message": ["role": "assistant", "content": [["type": "text", "text": "Done."]]]],
                    ["type": "user", "uuid": "u2", "timestamp": now, "origin": ["kind": "human"],
                     "message": ["role": "user", "content": "Now the tests"]],
                    ["type": "custom-title", "customTitle": "Slots rename"],
                ])
                transcript(app, folder: "-home-dev-api", session: "bbbbbbbb-0000-4000-8000-000000000002", [
                    ["type": "user", "uuid": "u3", "timestamp": old, "cwd": "/home/dev/api", "origin": ["kind": "human"],
                     "message": ["role": "user", "content": "An older question"]],
                    ["type": "custom-title", "customTitle": "Old work"],
                ])
                let week = app.runCommand(["week"]).output
                t.expect(week.contains("2 prompts in 1 conversation, 1 project, 1 day."), "counted: \(week)")
                t.expect(week.contains("events · 2 prompts, 1 conversation, 1 day: \u{201C}Slots rename\u{201D}"), "named: \(week)")
                t.expect(!week.contains("Old work") && !week.contains("api ·"), "ten days ago is not this week")
                t.expect(!week.contains("Rename the slots"), "counts, never the words")
            },
        ])
    }
}
