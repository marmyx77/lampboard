import LampBoardCore
import Foundation
import TestKit

/// The tutorial's script and tour: invented data only, and a tour that moves
/// on gestures, follows the version, and resumes where it was left.
enum TourSuite {

    static let today = Tour.steps()

    static let suite = TestSuite("Tutorial: the script and the tour", [

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

        TestCase("Today's tour shows only what 0.5 can do") { t in
            t.expectEqual(today.map(\.id), ["colours", "amber", "allowance", "lampmaster"])
            t.expectEqual(Tour.steps(available: Set(Tour.Feature.allCases)).count, 9, "every step once all is there")
        },

        TestCase("A step moves on with its own gesture, and with nothing else") { t in
            var progress = TourProgress.start(today)
            t.expectEqual(progress.position(in: today)?.index, 1)
            progress = progress.after(.rowOpened(session: "demo-api-00002"), in: today)
            t.expectEqual(progress.stepId, "colours", "the wrong row does not count")
            progress = progress.after(.rowOpened(session: "demo-docs-0001"), in: today)
            t.expectEqual(progress.stepId, "amber")
            progress = progress.after(.rowOpened(session: "demo-api-00002"), in: today)
                .after(.allowanceInspected, in: today)
                .after(.lampMasterAnswered, in: today)
            t.expectEqual(progress.status, .finished)
        },

        TestCase("Skipped, it resumes where it was; finished, it starts over") { t in
            let second = TourProgress.start(today).after(.rowOpened(session: "demo-docs-0001"), in: today)
            let skipped = second.skipped()
            t.expectNil(skipped.current(in: today), "nothing on screen once skipped")
            t.expectEqual(skipped.resumed(in: today).stepId, "amber")
            t.expectEqual(TourProgress(status: .finished).resumed(in: today).stepId, "colours")
            let unknown = TourProgress(status: .inProgress, stepId: "a-step-a-later-version-removed")
            t.expectEqual(unknown.current(in: today)?.id, "colours", "a step that is gone falls back to the first")
        },

        TestCase("Getting started ticks what the Mac already shows, and leaves the optional out of the count") { t in
            var facts = GettingStarted.Facts()
            t.expectEqual(GettingStarted.remaining(facts), 4, "hooks, accessibility, rename, reorder")
            facts.hooks = true
            facts.renamed = true
            t.expectEqual(GettingStarted.remaining(facts), 2)
            t.expect(GettingStarted.preparation(facts).first { $0.id == "hooks" }?.done == true, "hooks ticked")
            let answer = GettingStarted.firstSteps(facts).first { $0.id == "answer" }
            t.expectEqual(answer?.optional, true, "answering LampMaster is optional while it is off")
            facts.lampMaster = true
            t.expectEqual(GettingStarted.firstSteps(facts).first { $0.id == "answer" }?.optional, false, "and expected once it is on")
            t.expectEqual(GettingStarted.remaining(facts), 3)
        },

        TestCase("Progress survives the preferences by step id") { t in
            let progress = TourProgress(status: .inProgress, stepId: "allowance")
            let data = try? JSONEncoder().encode(progress)
            t.expectEqual(data.flatMap { try? JSONDecoder().decode(TourProgress.self, from: $0) }, progress)
        },
    ])
}
