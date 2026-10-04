import LampBoardCore
import Foundation
import TestKit

/// The row's second line: what the session is doing now, in a few words (UX §4).
enum RowActivitySuite {

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func row(
        _ status: SessionStatus, ask: PendingAsk? = nil, tool: RunningTool? = nil, message: String? = nil,
        reason: StopFailureReason? = nil, waitingOn: [String] = [], host: String? = nil, harness: Harness = .claudeCode
    ) -> ColumnRow {
        let session = SessionState(
            id: "s1", status: status, workspace: Workspace(path: "/home/dev/api", host: host), lastMessage: message,
            updatedAt: t0, statusSince: t0, failureReason: reason, harness: harness, pendingAsk: ask,
            waitingOn: waitingOn, runningTool: tool)
        return ColumnRow(id: "r1", workspace: session.workspace, sessions: [session])
    }

    private static func line(_ row: ColumnRow, at minutes: Double = 1) -> String {
        RowActivity.line(for: row, now: t0.addingTimeInterval(minutes * 60))
    }

    static let suite = TestSuite("What a row says it is doing", [

        TestCase("Amber says what it asks; red why it died") { t in
            t.expectEqual(line(row(.awaiting, ask: PendingAsk(tool: "Bash", detail: "npm publish"))), "Bash: npm publish")
            t.expectEqual(line(row(.awaiting)), "waiting for your answer")
            t.expectEqual(line(row(.failed, reason: .rateLimit)), "request limit reached")
        },

        TestCase("Yellow names the tool it is on, and says when it may be stuck") { t in
            let tool = RunningTool(tool: "Edit", detail: "src/api/routes.ts", since: t0)
            t.expectEqual(line(row(.working, tool: tool)), "Edit src/api/routes.ts")
            t.expectEqual(line(row(.working, tool: RunningTool(tool: "Bash", detail: "npm install", since: t0)), at: 16),
                          "stuck 16m on npm install")
            t.expectEqual(line(row(.working)), "working")
        },

        TestCase("Green gives the answer's first line; blue what holds it") { t in
            t.expectEqual(line(row(.ready, message: "Guide rewritten: 42 pages.\nSecond line.")), "Guide rewritten: 42 pages.")
            t.expectEqual(line(row(.waiting, waitingOn: ["monitor", "monitor", "shell"])), "waiting on monitor ×2, shell")
        },

        TestCase("At rest, the agent; on another machine, the machine too") { t in
            t.expectEqual(line(row(.idle)), "Claude Code")
            t.expectEqual(line(row(.idle, host: "buildbox", harness: .codex)), "Codex · @buildbox")
            t.expectEqual(line(row(.awaiting, host: "buildbox")), "@buildbox · waiting for your answer")
        },

        TestCase("A blank first line is skipped, and a tab keeps two words apart") { t in
            t.expectEqual(line(row(.ready, message: "   \nDone.")), "Done.")
            t.expectEqual(line(row(.ready, message: "a\tb")), "a b")
            t.expectEqual(line(row(.ready, message: "\u{202E}evil")), "evil", "no bidi override")
        },

        TestCase("A project of several says the most urgent one, and how many more") { t in
            let a = SessionState(id: "a", status: .awaiting, workspace: Workspace(path: "/home/dev/api"), updatedAt: t0,
                                 statusSince: t0, pendingAsk: PendingAsk(tool: "Bash", detail: "ls"))
            let b = SessionState(id: "b", status: .idle, workspace: Workspace(path: "/home/dev/api"), updatedAt: t0, statusSince: t0)
            let group = ColumnRow(id: "g", workspace: a.workspace, sessions: [a, b])
            t.expectEqual(RowActivity.line(for: group, now: t0), "Bash: ls · +1")
        },

        TestCase("One line, never a paragraph") { t in
            let long = String(repeating: "word ", count: 80)
            t.expect(line(row(.ready, message: long)).count <= RowActivity.maxLength, "cut")
            t.expect(!line(row(.ready, message: "a\u{1B}[2Jb")).unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) },
                     "no control character")
        },
    ])
}
