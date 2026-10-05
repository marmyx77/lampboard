import LampBoardCore
import Foundation
import TestKit

/// The fifth job (D3): a failure some other conversation met before, found by
/// searching first — deterministic, no token — and given to the round as
/// candidates, never asked of the model's memory.
enum LampMasterPrecedentsSuite {

    typealias F = LampMasterFixtures

    static let failing = LampMasterSession(card: F.card("cccccccc-0000-4000-8000-000000000003", [
        F.prompt("make the tests pass", at: 0, cwd: "/home/dev/events"),
        F.call("t1", tool: "Bash", input: ["command": "pnpm test"], at: 1, cwd: "/home/dev/events"),
        F.result("t1", error: true, text: "Error: GET /api/v2/slots returned 404 at line 12", at: 2, cwd: "/home/dev/events"),
    ]), liveness: .idle)

    static func hit(_ id: String, _ project: String?, daysAgo: Double, _ snippet: String = "renamed «slots» to availability")
        -> LampMasterPrecedents.Hit {
        LampMasterPrecedents.Hit(sessionId: id, project: project, lastAt: F.at(10).addingTimeInterval(-daysAgo * 86_400), snippet: snippet)
    }

    static let suite = TestSuite("LampMaster: precedents", [

        TestCase("A failure keeps the words a search needs, which the fingerprint takes out") { t in
            let terms = FailureFingerprint.terms(of: "npm WARN deprecated\nError: GET /api/v2/slots returned 404 at line 12")
            t.expectEqual(terms, ["get", "api", "slots"], "the error line's names, without the words every error has")
            t.expectEqual(FailureFingerprint.terms(of: "fatal: 3f9a2c1d0b not found in /tmp/x"), ["tmp"], "no hash, no number")
            t.expectEqual(failing.card.failures.first?.terms, ["get", "api", "slots"], "and the card keeps them")
        },

        TestCase("Another project, or another day: one session's own conversation is no precedent") { t in
            let found = LampMasterPrecedents.pick([
                hit("cccccccc-0000-4000-8000-000000000003", "events", daysAgo: 0, "itself"),
                hit("dddddddd-0000-4000-8000-000000000004", "events", daysAgo: 0.2, "same project, same day"),
                hit("eeeeeeee-0000-4000-8000-000000000005", "infra", daysAgo: 0.1, "infra fixed it"),
                hit("ffffffff-0000-4000-8000-000000000006", "events", daysAgo: 20, "events, three weeks ago"),
            ], for: failing, now: F.at(10))
            t.expectEqual(found.map(\.id), ["eeeeeeee", "ffffffff"])
            t.expectEqual(found.first?.project, "infra")
            t.expectEqual(found.last?.date, "2026-12-26", "a day, not a time")
        },

        TestCase("At most three, each snippet one clean line of at most 300 characters") { t in
            let many = (1...6).map { hit("aaaaaaa\($0)-0000-4000-8000-000000000000", "p\($0)", daysAgo: 2, "line one\nline two " + String(repeating: "x", count: 400)) }
            let found = LampMasterPrecedents.pick(many, for: failing, now: F.at(10))
            t.expectEqual(found.count, 3)
            t.expect(found.allSatisfy { $0.snippet.count <= 300 && !$0.snippet.contains("\n") }, "clipped and flat")
        },

        TestCase("The round's frame carries them; a frame over budget drops them before any session's detail") { t in
            var asked: [String] = []
            let precedents = LampMasterPrecedents.frame(for: [failing], now: F.at(10)) { words in
                asked.append(words)
                return [hit("eeeeeeee-0000-4000-8000-000000000005", "infra", daysAgo: 1, "fixed the «slots» 404")]
            }
            t.expectEqual(asked, ["get api slots"], "one search, with the failure's words")
            t.expectEqual(precedents.first?.session, "cccccccc")
            t.expectEqual(precedents.first?.error, failing.card.failures.first?.fingerprint)
            let frame = LampMasterFrameBuilder.build(sessions: [failing], now: F.at(10), precedents: precedents)
            t.expect(frame.json().contains("\"precedents\""), "in the frame")
            t.expect(frame.json().contains("fixed the «slots» 404"), "with what was said")
            let tight = LampMasterFrameBuilder.build(sessions: [failing], now: F.at(10), precedents: precedents,
                                                     budgetTokens: frame.estimatedTokens - 1)
            t.expectNil(tight.precedents, "the first thing to go")
            t.expectEqual(tight.sessions.count, 1, "the session stays")
            t.expect(!LampMasterFrameBuilder.build(sessions: [failing], now: F.at(10)).json().contains("precedents"),
                     "none, and the key is not there")
        },

        TestCase("Added once the round runs: only for sessions the frame kept, never in its digest") { t in
            let base = LampMasterFrameBuilder.build(sessions: [failing], now: F.at(10))
            var frame = base
            let found = [LampMasterFrame.Precedent.Found(id: "eeeeeeee", project: "infra", date: "2027-01-14", snippet: "fixed")]
            LampMasterFrameBuilder.add([.init(session: "cccccccc", error: "e", found: found),
                                        .init(session: "notthere", error: "e", found: found)], to: &frame)
            t.expectEqual(frame.precedents?.map(\.session), ["cccccccc"], "a session out of the frame has none")
            t.expectEqual(LampMasterSchedule.digest(frame), LampMasterSchedule.digest(base), "a precedent alone is no reason to run")
        },

        TestCase("The same project counts from a day on, not before") { t in
            let now = F.at(10)
            let day = LampMasterPrecedents.Hit(sessionId: "dddddddd-1", project: "events", lastAt: now.addingTimeInterval(-86_400), snippet: "s")
            let almost = LampMasterPrecedents.Hit(sessionId: "dddddddd-2", project: "events", lastAt: now.addingTimeInterval(-86_399), snippet: "s")
            t.expectEqual(LampMasterPrecedents.pick([day, almost], for: failing, now: now).map(\.id), ["dddddddd"])
            t.expectEqual(LampMasterPrecedents.pick([almost], for: failing, now: now).count, 0)
        },

        TestCase("No words worth a search, no search; never more than four failures searched") { t in
            var searched = 0
            let vague = LampMasterSession(card: F.card("bbbbbbbb-0000-4000-8000-000000000002", [
                F.call("t1", tool: "Bash", input: ["command": "make"], at: 1),
                F.result("t1", error: true, text: "Error: failed", at: 2),
            ]), liveness: .idle)
            _ = LampMasterPrecedents.frame(for: [vague], now: F.at(10)) { _ in searched += 1; return [] }
            t.expectEqual(searched, 0)
            let names = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"]
            let noisy = LampMasterSession(card: F.card("aaaaaaaa-0000-4000-8000-000000000001", names.enumerated().flatMap { n, name in [
                F.call("t\(n)", tool: "Bash", input: ["command": "x"], at: Double(n)),
                F.result("t\(n)", error: true, text: "Error: module \(name) missing", at: Double(n)),
            ] }), liveness: .idle)
            _ = LampMasterPrecedents.frame(for: [noisy], now: F.at(10)) { _ in searched += 1; return [] }
            t.expectEqual(searched, 4)
        },
    ])
}
