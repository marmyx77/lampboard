import LampBoardCore
import Foundation
import TestKit

/// The radar (§4.4): before a session writes a file, whether another live session
/// of the same checkout wrote it lately — so the second one stops and asks first.
enum RadarSuite {

    static let now = FileConflictsSuite.now

    static let suite = TestSuite("Radar", [

        TestCase("Another live session's recent write of the same file is found, the latest; mine and old ones are not") { t in
            let logs = [
                "a": FileConflictsSuite.log([("Edit", "/home/dev/api/src/routes.ts", 30)]),
                "b": FileConflictsSuite.log([("Write", "/home/dev/api/src/routes.ts", 12)]),
                "c": FileConflictsSuite.log([("Edit", "/home/dev/api/src/routes.ts", 200)]),
                "me": FileConflictsSuite.log([("Edit", "/home/dev/api/src/routes.ts", 1)]),
            ]
            let found = FileConflicts.lastWriter(of: "/home/dev/api/src/routes.ts", besides: "me", logs: logs,
                                                 live: ["a", "b", "c", "me"], now: now)
            t.expectEqual(found?.session, "b", "the most recent other writer")
            t.expectEqual(found.map { Int(now.timeIntervalSince($0.at) / 60) }, 12)
            t.expectNil(FileConflicts.lastWriter(of: "/home/dev/api/src/routes.ts", besides: "me", logs: logs,
                                                 live: ["c", "me"], now: now), "only an old write, or a closed session")
            t.expectNil(FileConflicts.lastWriter(of: "/home/dev/api/README.md", besides: "me", logs: logs,
                                                 live: ["a", "b", "me"], now: now), "a file nobody else wrote")
        },

        TestCase("A path is compared as the log keeps it: a long one past the cut still matches") { t in
            let long = "/home/dev/api/" + String(repeating: "deep/", count: 30) + "routes.ts"
            var log = SessionActivity()
            let wire = #"{"v":1,"kind":"tool","session":"e2e0d0d0-0000-4000-8000-0000000000bb","id":"c1","tool":"Edit","phase":"start","detail":"\#(long)"}"#
            guard let report = try? ModReport.decode(Data(wire.utf8)) else { return t.fail("report not read") }
            log.record(report, at: now.addingTimeInterval(-60))
            t.expectEqual(FileConflicts.lastWriter(of: long, besides: "me", logs: ["b": log], live: ["b", "me"], now: now)?.session, "b")
            t.expectEqual(LampMasterLookup.cleanForTests("a\u{200D}b\u{202E}c\u{200B}d"), "a\u{200D}b cd",
                          "a joiner kept, a bidi override a space, an invisible gone")
        },

        TestCase("The sentence names the file, the other session and when, in its own words") { t in
            t.expectEqual(RadarExchange.reason(file: "/home/dev/api/src/routes.ts", by: "api gateway", minutesAgo: 12),
                          "routes.ts was written by \u{201C}api gateway\u{201D} 12 minutes ago: check with it before changing it.")
            t.expectEqual(RadarExchange.reason(file: "/x/a.md", by: "docs\u{202E}evil\nline", minutesAgo: 0),
                          "a.md was written by \u{201C}docs evil line\u{201D} just now: check with it before changing it.")
        },

        TestCase("The mod is heard only proven for its session and file; the answer is signed over what it says") { t in
            let key = String(repeating: "ab", count: 16), nonce = "0123456789abcdef0123"
            let session = "e2e0d0d0-0000-4000-8000-0000000000aa", file = "/home/dev/api/src/routes.ts"
            let body = Data(#"{"v":1,"session":"\#(session)","file":"\#(file)"}"#.utf8)
            let proof = PermissionGate.mac(key: key, message: RadarExchange.proofMessage(nonce: nonce, session: session, file: file))
            t.expectEqual(RadarExchange.provenRequest(body, nonce: nonce, proof: proof, key: key)?.file, file)
            t.expectNil(RadarExchange.provenRequest(body, nonce: nonce, proof: nil, key: key), "no proof")
            let clear = RadarExchange.answer(reason: nil, nonce: nonce, key: key)
            t.expectEqual(clear, "clear " + PermissionGate.mac(key: key, message: "radar:\(nonce):clear:"))
            let written = RadarExchange.answer(reason: "x was written", nonce: nonce, key: key)
            t.expect(written.hasPrefix("written ") && written.hasSuffix("\nx was written"), written)
        },
    ])
}
