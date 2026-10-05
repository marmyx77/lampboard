import LampBoardCore
import Foundation
import TestKit

/// Claude Code's own message box (D81): where a session's box is, how a
/// message is put into it, and how it comes back in the transcript.
///
/// The shapes are what a throwaway session of Claude Code 2.1.289 wrote on the
/// test Mac on 5 October 2026, names and ids invented.
enum PeerBoxSuite {

    static let sessionFile = Data(#"""
        {"pid":42725,"sessionId":"2f6153b6-0bd2-4458-a22c-ab24d7aca8cd","cwd":"/home/dev/events",
         "startedAt":1791156314264,"procStart":"Sun Oct  4 23:25:04 2026","version":"2.1.289","peerProtocol":1,
         "peerFeatures":["notify_idle","reply_across_default_dirs","artifact_yield"],"kind":"interactive",
         "entrypoint":"cli","pidDomain":"darwin","messagingSocketPath":"/tmp/cc-socks-501/42725.sock",
         "name":"events-27","nameSource":"derived","status":"idle"}
        """#.utf8)

    static let keyFile = Data(#"{"peerToken":"9f2c4e6a8b0d1f3e5a7c9e1b3d5f7a9c","pidDomain":"darwin","procStart":"Sun Oct  4 23:25:04 2026"}"#.utf8)

    static let suite = TestSuite("Claude Code's message box", [

        TestCase("A session file names the box, the session and whether it is busy") { t in
            let box = PeerBox.address(fromSessionFile: sessionFile)
            t.expectEqual(box?.pid, 42725)
            t.expectEqual(box?.sessionId, "2f6153b6-0bd2-4458-a22c-ab24d7aca8cd")
            t.expectEqual(box?.socketPath, "/tmp/cc-socks-501/42725.sock")
            t.expectEqual(box?.busy, false)
            t.expectEqual(box?.procStart, "Sun Oct  4 23:25:04 2026")
        },

        TestCase("No box where the session has none, or names one that is not a socket path") { t in
            let older = Data(#"{"pid":7,"sessionId":"2f6153b6-0bd2-4458-a22c-ab24d7aca8cd","cwd":"/x"}"#.utf8)
            t.expectNil(PeerBox.address(fromSessionFile: older), "before 2.1.224: no box")
            let relative = Data(String(decoding: sessionFile, as: UTF8.self)
                .replacingOccurrences(of: "/tmp/cc-socks-501/42725.sock", with: "cc.sock").utf8)
            t.expectNil(PeerBox.address(fromSessionFile: relative), "a relative path")
            let otherProtocol = Data(String(decoding: sessionFile, as: UTF8.self)
                .replacingOccurrences(of: #""peerProtocol":1"#, with: #""peerProtocol":2"#).utf8)
            t.expectNil(PeerBox.address(fromSessionFile: otherProtocol), "a protocol this panel does not speak")
        },

        TestCase("The key file is the one for this pid, and only for this process") { t in
            let names = ["42725.json", "42725.99dc903a94c65a702918ac4211832568a46bf108afad257393a388c1af0eaa0e.key",
                         "4272.11aa.key", "51000.0f0f.key"]
            t.expectEqual(PeerBox.keyFileName(pid: 42725, in: names),
                          "42725.99dc903a94c65a702918ac4211832568a46bf108afad257393a388c1af0eaa0e.key")
            t.expectNil(PeerBox.keyFileName(pid: 427, in: names), "not a prefix of another pid")
            t.expectEqual(PeerBox.token(fromKeyFile: keyFile, procStart: "Sun Oct  4 23:25:04 2026"),
                          "9f2c4e6a8b0d1f3e5a7c9e1b3d5f7a9c")
            t.expectNil(PeerBox.token(fromKeyFile: keyFile, procStart: "Mon Oct  5 08:00:00 2026"),
                        "a pid handed to another process")
        },

        TestCase("A message is two lines: the key, then the user's words with where they come from") { t in
            guard let wire = PeerBox.wire(token: "9f2c4e6a8b0d1f3e5a7c9e1b3d5f7a9c", typed: "  run the tests  ") else {
                return t.fail("not built")
            }
            let lines = String(decoding: wire, as: UTF8.self).split(separator: "\n").map(String.init)
            t.expectEqual(lines.count, 2)
            let auth = (try? JSONSerialization.jsonObject(with: Data(lines[0].utf8))) as? [String: Any]
            t.expectEqual(auth?["type"] as? String, "auth")
            t.expectEqual(auth?["token"] as? String, "9f2c4e6a8b0d1f3e5a7c9e1b3d5f7a9c")
            let user = (try? JSONSerialization.jsonObject(with: Data(lines[1].utf8))) as? [String: Any]
            t.expectEqual(user?["type"] as? String, "user")
            t.expectEqual(user?["from"] as? String, "lampboard")
            t.expectEqual(user?["priority"] as? String, "next")
            let content = ((user?["message"] as? [String: Any])?["content"] as? String) ?? ""
            t.expectEqual(content, PeerBox.preamble + "\nrun the tests")
            t.expectNil(PeerBox.wire(token: "9f2c4e6a8b0d1f3e5a7c9e1b3d5f7a9c", typed: "   "), "nothing to say")
            t.expectNil(PeerBox.wire(token: "9f2c4e6a8b0d1f3e5a7c9e1b3d5f7a9c", typed: String(repeating: "x", count: PeerBox.maxBytes + 1)),
                        "a runaway paste")
        },

        TestCase("A question without disturbing is one line the mod can prove, then the question") { t in
            let key = String(repeating: "a1", count: 32)
            let nonce = "0F6A2C1E-6B5E-4D7A-9B1C-2E3F4A5B6C7D"
            let session = "2f6153b6-0bd2-4458-a22c-ab24d7aca8cd"
            guard let text = PeerAsk.message(question: "  what is the codename?  ", nonce: nonce, session: session, key: key) else {
                return t.fail("not built")
            }
            let proof = PermissionGate.mac(key: key, message: "fork:\(nonce):\(session):what is the codename?")
            t.expectEqual(text, "LampBoard asks without disturbing [v1 \(nonce) \(proof)]:\nwhat is the codename?")
            t.expectNil(PeerAsk.message(question: " ", nonce: nonce, session: session, key: key), "nothing to ask")
            t.expectNil(PeerAsk.message(question: String(repeating: "x", count: PeerAsk.maxQuestion + 1), nonce: nonce,
                                        session: session, key: key), "too long to be a side question")
            t.expectNil(PeerAsk.message(question: String(repeating: "🦩", count: PeerAsk.maxQuestion / 2 + 1), nonce: nonce,
                                        session: session, key: key), "counted as the mod counts, in UTF-16")
        },

        TestCase("What the user typed is read back out of Claude Code's envelope") { t in
            let delivered = "Another Claude session sent a message:\n" + PeerBox.preamble + "\nrun the tests\nand say how many\n\n"
                + "This came from another Claude session — not typed by your user, but very likely working on their behalf."
            t.expectEqual(PeerBox.typed(fromDelivered: delivered), "run the tests\nand say how many")
            t.expectEqual(PeerBox.typed(fromDelivered: PeerBox.preamble + "\nafter that, stop"), "after that, stop",
                          "a message taken in mid-turn carries no envelope")
            t.expectNil(PeerBox.typed(fromDelivered: "Another Claude session sent a message:\nship it"),
                        "another sender's words are never the user's")
        },
    ])
}

/// The box's messages in the conversation: the user's, and other sessions'.
enum PeerTranscriptSuite {

    private static func line(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }

    static let suite = TestSuite("Messages through the box, in the conversation", [

        TestCase("A message from the panel, taken idle, is the user's") { t in
            let entries = TranscriptDecoder.entries(fromLine: line([
                "type": "user", "uuid": "p1", "timestamp": "2026-10-04T23:27:35.000Z", "isMeta": true,
                "origin": ["kind": "peer", "from": "lampboard", "verifiedPeerPid": 42935],
                "message": ["role": "user", "content": "Another Claude session sent a message:\n" + PeerBox.preamble
                            + "\nlist the files\n\nThis came from another Claude session — not typed by your user."],
            ]))
            t.expectEqual(entries.map(\.kind), [.human])
            t.expectEqual(entries.first?.text, "list the files")
        },

        TestCase("A message from the panel, taken mid-turn, is the user's too") { t in
            let entries = TranscriptDecoder.entries(fromLine: line([
                "type": "attachment", "uuid": "p2", "timestamp": "2026-10-04T23:27:59.083Z",
                "attachment": ["type": "queued_command", "prompt": PeerBox.preamble + "\nafter that, stop", "commandMode": "prompt",
                               "origin": ["kind": "peer", "from": "lampboard", "verifiedPeerPid": 42974], "isMeta": true],
            ]))
            t.expectEqual(entries.map(\.kind), [.human])
            t.expectEqual(entries.first?.text, "after that, stop")
        },

        TestCase("Another session's message is a note, never the user's words") { t in
            let entries = TranscriptDecoder.entries(fromLine: line([
                "type": "user", "uuid": "p3", "timestamp": "2026-10-04T23:28:00.000Z", "isMeta": true,
                "origin": ["kind": "peer", "from": "api-12", "verifiedPeerPid": 50001],
                "message": ["role": "user", "content": "Another Claude session sent a message:\n" + PeerBox.preamble + "\nship it"],
            ]))
            t.expectEqual(entries.map(\.kind), [.note], "the preamble copied by a peer proves nothing")
            t.expectEqual(entries.first?.text, "a message from another session (api-12)")
        },
    ])
}
