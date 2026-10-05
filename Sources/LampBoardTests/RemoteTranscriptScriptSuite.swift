import LampBoardCore
import Foundation
import TestKit

/// A node's transcripts read for LampMaster's cards (D4): one ssh per node and
/// round, each file from where the last read stopped. The script itself is run
/// for real by the end-to-end suite; here, what it is asked and what it answers.
enum RemoteTranscriptScriptSuite {

    static let path = "/home/dev/.claude/projects/-home-dev-api/aaaaaaaa-0000-4000-8000-000000000001.jsonl"

    static let suite = TestSuite("LampMaster: a node's transcripts", [

        TestCase("Only a transcript's path is asked for: absolute, under a projects folder, a .jsonl") { t in
            t.expect(RemoteTranscriptScript.isTranscriptPath(path), "a transcript")
            t.expect(!RemoteTranscriptScript.isTranscriptPath("relative/.claude/projects/x.jsonl"), "relative")
            t.expect(!RemoteTranscriptScript.isTranscriptPath("/home/dev/.ssh/id_ed25519"), "anything else")
            t.expect(!RemoteTranscriptScript.isTranscriptPath("/home/dev/.claude/projects/../../.ssh/x.jsonl"), "climbing out")
            t.expect(!RemoteTranscriptScript.isTranscriptPath("/home/dev/.claude/projects/a\n.jsonl"), "a line break")
        },

        TestCase("The asks travel as base64, so no path can break the program it is pasted into") { t in
            let asks = [RemoteTranscriptScript.Ask(id: "aaaaaaaa-1", path: path + "'''\"\"\"", offset: 42),
                        RemoteTranscriptScript.Ask(id: "bbbbbbbb-2", path: path, offset: 0)]
            let script = RemoteTranscriptScript.script(asks, tail: 1_000)
            t.expect(!script.contains("aaaaaaaa-1") && !script.contains("-home-dev-api"), "nothing of the asks in clear")
            t.expect(script.contains("TAIL = 1000"), "the first read's size")
            let payload = script.components(separatedBy: "b64decode('").dropFirst().first?.components(separatedBy: "')").first ?? ""
            let decoded = Data(base64Encoded: payload).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
            t.expectEqual(decoded?.count, 1, "an ask whose path is not a transcript's is not sent")
            t.expectEqual(decoded?.first?["offset"] as? Int, 0)
        },

        TestCase("The answer: only what was asked, and only what adds up") { t in
            let body = #"{"bbbbbbbb-2": {"size": 900, "start": 400, "data": "eyJhIjoxfQo="}, "cccc": {"size": "x"}, "dddd": 3, "eeee": {"size": 9, "start": 0, "data": ""}}"#
            let reads = RemoteTranscriptScript.decode(Data(body.utf8), asked: ["bbbbbbbb-2", "cccc", "dddd"])
            t.expectEqual(reads, [RemoteTranscriptScript.Read(id: "bbbbbbbb-2", size: 900, start: 400, data: Data("{\"a\":1}\n".utf8))],
                          "an id never asked for is dropped, and so is what does not read")
            t.expectEqual(RemoteTranscriptScript.decode(Data("not json".utf8), asked: ["a"]).count, 0)
            for bad in [#"{"start": 18446744073709551615, "size": 18446744073709551615}"#, #"{"start": -1, "size": 10}"#,
                        #"{"start": 1.5, "size": 10}"#, #"{"start": true, "size": 10}"#, #"{"start": 8, "size": 10}"#] {
                let entry = bad.dropLast() + #", "data": "YWJjZA=="}"#
                t.expectEqual(RemoteTranscriptScript.decode(Data(#"{"a": \#(entry)}"#.utf8), asked: ["a"]).count, 0,
                              "refused: \(bad)")
            }
        },

        TestCase("Whole lines only: a record or a character cut by the read's end waits for the next") { t in
            t.expectEqual(RemoteTranscriptScript.wholeLines(Data("a\nb\nc".utf8)), Data("a\nb\n".utf8))
            t.expectEqual(RemoteTranscriptScript.wholeLines(Data("città".utf8).dropLast()), Data(), "half an à is not a line")
        },
    ])
}
