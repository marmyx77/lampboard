import LampBoardCore
import Foundation
import TestKit

/// A working session that has sat on one tool too long (plan 5.7).
enum StuckSuite {

    private static let id = "5f0c2a7e-1b3d-4c8e-9a6f-2d4b8e1c7a90"
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func tool(_ phase: String, _ call: String = "toolu_01AbC", detail: String? = "npm test") -> String {
        #"{"v":1,"kind":"tool","session":"\#(id)","id":"\#(call)","tool":"Bash","phase":"\#(phase)""#
            + (detail.map { #","detail":"\#($0)""# } ?? "") + "}"
    }

    private static func report(_ json: String) -> ModReport? { try? ModReport.decode(Data(json.utf8)) }

    private static func working(tool: RunningTool?) -> SessionState {
        SessionState(id: id, status: .working, workspace: Workspace(path: "/home/dev/api"),
                     updatedAt: t0, statusSince: t0, runningTool: tool)
    }

    static let suite = TestSuite("A session stuck on one tool", [

        TestCase("A tool's start and end are read, its line kept to one printable line") { t in
            t.expectEqual(report(tool("start")), .tool(session: id, run: .init(id: "toolu_01AbC", tool: "Bash", detail: "npm test", finished: false)))
            t.expectEqual(report(tool("end", detail: nil)), .tool(session: id, run: .init(id: "toolu_01AbC", tool: "Bash", detail: nil, finished: true)))
            guard case .tool(_, let run)? = report(tool("start", detail: #"rm -rf x\u001b[2J\nand more"#)) else { return t.fail("not read") }
            t.expect(run.detail?.contains("\u{1B}") == false, "no control character: \(run.detail ?? "")")
            t.expect(run.detail?.contains("\n") == false, "one line")
            t.expectNil(report(#"{"v":1,"kind":"tool","session":"\#(id)","id":"a b","tool":"Bash","phase":"start"}"#), "a call id with a space")
            t.expectNil(report(#"{"v":1,"kind":"tool","session":"\#(id)","id":"toolu_1","tool":"Bash","phase":"halfway"}"#), "a phase")
        },

        // Commands carry secrets, and this one is shown on a card that may be on
        // a shared screen.
        TestCase("What looks like a secret in a command is masked") { t in
            func shown(_ line: String) -> String? {
                guard case .tool(_, let run)? = report(tool("start", detail: line)) else { return nil }
                return run.detail
            }
            t.expectEqual(shown("GITHUB_TOKEN=ghp_abc123 gh pr list"), "GITHUB_TOKEN=*** gh pr list")
            t.expectEqual(shown("curl https://sam:hunter2@example.net/x"), "curl https://sam:***@example.net/x")
            t.expectEqual(shown(#"curl -H 'Authorization: Bearer abc' x"#), #"curl -H 'Authorization: *** x"#)
            t.expectEqual(shown("db --password s3cret --user sam"), "db --password *** --user sam")
            t.expectEqual(shown("npm test"), "npm test", "an ordinary line untouched")
            t.expect(shown(#"echo \u202Eevil"#)?.contains("\u{202E}") == false, "no bidi override")
        },

        // The mod does not wait for its posts: a fast tool's end can arrive first.
        TestCase("An end that arrives before its start leaves nothing running") { t in
            var ledger = ModLedger()
            ledger = ledger.applying(report(tool("end", "toolu_fast", detail: nil))!, now: t0)
            ledger = ledger.applying(report(tool("start", "toolu_fast"))!, now: t0)
            t.expectNil(ledger.longestRunning(in: id))
        },

        TestCase("A subagent's call is not tracked, and a call from before this turn is not this turn's") { t in
            var ledger = ModLedger()
            let agent = #"{"v":1,"kind":"tool","session":"\#(id)","id":"toolu_ag","tool":"Agent","phase":"start"}"#
            ledger = ledger.applying(report(agent)!, now: t0)
            t.expectNil(ledger.longestRunning(in: id), "Agent runs as long as its subagent")
            ledger = ledger.applying(report(tool("start", "toolu_old"))!, now: t0)
            t.expectNil(ledger.longestRunning(in: id, since: t0.addingTimeInterval(3600)), "an end that never came")
            t.expectNotNil(ledger.longestRunning(in: id, since: t0))
        },

        TestCase("The ledger holds what runs, forgets what ended, and keeps it across a measure") { t in
            var ledger = ModLedger()
            ledger = ledger.applying(report(tool("start", "toolu_a"))!, now: t0)
            ledger = ledger.applying(report(tool("start", "toolu_b", detail: "swift build"))!, now: t0.addingTimeInterval(60))
            ledger = ledger.applying(.measure(session: id, measure: .init(tokens: 1, window: 2, model: nil, rateLimits: [], costUSD: nil)),
                                     now: t0.addingTimeInterval(90))
            t.expectEqual(ledger.longestRunning(in: id)?.detail, "npm test", "the oldest one")
            ledger = ledger.applying(report(tool("end", "toolu_a", detail: nil))!, now: t0.addingTimeInterval(120))
            t.expectEqual(ledger.longestRunning(in: id)?.detail, "swift build")
            ledger = ledger.applying(.end(session: id, reason: .exit), now: t0.addingTimeInterval(130))
            t.expectNil(ledger.longestRunning(in: id), "a session's end takes its tools with it")
        },

        TestCase("A sender that never says end cannot grow the list") { t in
            var ledger = ModLedger()
            for n in 0..<(ModLedger.maxRunning + 10) {
                ledger = ledger.applying(report(tool("start", "toolu_\(n)"))!, now: t0)
            }
            t.expectEqual(ledger.sessions[id]?.running.count, ModLedger.maxRunning)
        },

        TestCase("Stuck after a quarter of an hour on one tool, and only while working") { t in
            let tool = RunningTool(tool: "Bash", detail: "npm test", since: t0)
            t.expectNil(working(tool: tool).stuckTool(at: t0.addingTimeInterval(14 * 60)), "fourteen minutes is a long test")
            t.expectEqual(working(tool: tool).stuckTool(at: t0.addingTimeInterval(20 * 60)), tool)
            let card = RowSummary.of(ColumnRow(id: "r", workspace: working(tool: tool).workspace, sessions: [working(tool: tool)]),
                                     now: t0.addingTimeInterval(22 * 60))
            let line = card.fields.first { $0.label == "stuck?" }
            t.expectEqual(line?.value, "Bash: npm test")
            t.expect(line?.detail?.contains("22") == true, "how long: \(line?.detail ?? "")")
        },

        // An "end" the mod never sent must not make the next turn look stuck.
        TestCase("A turn that stops working takes its running tool with it") { t in
            let tool = RunningTool(tool: "Bash", detail: "npm test", since: t0)
            let done = working(tool: tool).with(status: .ready, at: t0.addingTimeInterval(60))
            t.expectNil(done.runningTool)
            let again = working(tool: tool).with(status: .working, at: t0.addingTimeInterval(60))
            t.expectEqual(again.runningTool, tool, "still working keeps it")
        },
    ])
}
