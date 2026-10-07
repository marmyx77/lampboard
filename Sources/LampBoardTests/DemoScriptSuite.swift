import LampBoardCore
import Foundation
import TestKit

/// The demo's script (D64, D120): invented data only — it is what the
/// screenshots show — and the answers it plays where a mod or a model would.
enum DemoScriptSuite {

    static let suite = TestSuite("The demo's script", [
        TestCase("The standard script holds nothing that belongs to anybody") { t in
            t.expectEqual(DemoScriptCheck.problems(.standard), [])
        },

        TestCase("A real address, a real project or a home path is caught") { t in
            let base = DemoScript.standard
            let leaky = DemoScript(
                sessions: base.sessions + [.init(id: "x", folder: "private-thing", title: "/home/dev/notes", model: "m")],
                beats: base.beats + [.init(at: 30, session: "ghost", kind: .prompt, text: nil)],
                account: "someone@gmail.com", allowanceUsed: 0.1, allowanceResetMinutes: 10, suggestion: base.suggestion)
            let problems = DemoScriptCheck.problems(leaky)
            t.expect(problems.contains { $0.contains("example.com") }, "the account")
            t.expect(problems.contains { $0.contains("private-thing") }, "the project")
            t.expect(problems.contains { $0.contains("ghost") }, "a beat for a session that is not there")
            t.expect(problems.contains { $0.contains("/home/") }, "a home path")
        },

        TestCase("A beat becomes the payload the installed hook would post") { t in
            let script = DemoScript.standard
            let amber = script.beats.first { $0.kind == .permission }!
            let payload = script.payload(for: amber, work: "/tmp/trial/work")
            t.expectEqual(payload["hook_event_name"] as? String, "Notification")
            t.expectEqual(payload["notification_type"] as? String, "permission_prompt")
            t.expectEqual(payload["cwd"] as? String, "/tmp/trial/work/api")
            let answer = script.payload(for: script.beats.first { $0.kind == .answer }!, work: "/w")
            t.expectEqual(answer["hook_event_name"] as? String, "Stop")
            t.expectNotNil(answer["last_assistant_message"])
        },

        TestCase("LampMaster's demo suggestion names sessions of the script by their short ids") { t in
            let script = DemoScript.standard
            let shortIds = Set(script.sessions.map { String($0.id.prefix(8)) })
            t.expect(script.suggestion.sessions.allSatisfy(shortIds.contains), "every session it names is in the script")
            t.expectNotNil(try? JSONSerialization.jsonObject(with: Data(script.json().utf8)), "the export parses")
        },

        TestCase("The trial's allowance line is the script's invented account") { t in
            let report = DemoScript.standard.allowanceReport(now: Date(timeIntervalSince1970: 1_800_000_000))
            t.expectEqual(report.account?.email, "design@example.com")
            t.expectEqual(report.limits.limits.first?.percent, 62)
            t.expectEqual(report.limits.limits.first?.resetsAt, Date(timeIntervalSince1970: 1_800_000_000 + 95 * 60))
        },

        TestCase("The trial's permission is the script's own: api asking to run npm publish, with what it would do") { t in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            guard let held = DemoScript.standard.heldPermission(now: now) else { return t.fail("no permission in the script") }
            t.expectEqual(held.sessionId, "demo-api-00002")
            t.expectEqual(held.tool, "Bash")
            t.expectEqual(held.line, "Bash: npm publish")
            t.expectEqual(held.receivedAt, now)
            t.expect(held.options.isEmpty, "a permission, not a question")
        },

        TestCase("A side question to events and a question to LampMaster have the script's answers; nothing else does") { t in
            let script = DemoScript.standard
            t.expect(script.sideAnswer(for: "demo-events-03").contains("/api/v2/slots"), "events knows the calendar")
            t.expect(script.sideAnswer(for: "demo-docs-0001").hasPrefix("In the trial"), "another session: said plainly")
            t.expect(script.lampMasterAnswer.contains("api"), "LampMaster names who renamed it")
            t.expect(DemoScriptCheck.problems(script).isEmpty, "the answers hold nothing real")
        },
    ])
}
