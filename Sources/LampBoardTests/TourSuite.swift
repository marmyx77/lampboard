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

        TestCase("Today's tour: all twelve steps, the scripted answers included") { t in
            t.expectEqual(today.map(\.id), ["colours", "amber", "allow", "depths", "plancia", "command", "squad", "allowance",
                                             "focus", "away", "lampmaster", "ask"])
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

        TestCase("The trial's card is put only on the allow step; a stopped tour waits; past it, never again") { t in
            func at(_ id: String, _ status: TourProgress.Status = .inProgress) -> TourProgress { TourProgress(status: status, stepId: id) }
            t.expectEqual(Tour.trialPermission(at("allow"), steps: today, waiting: true, shown: false), .stage)
            t.expectEqual(Tour.trialPermission(at("allow"), steps: today, waiting: true, shown: true), .wait, "already there")
            t.expectEqual(Tour.trialPermission(at("allow"), steps: today, waiting: false, shown: false), .wait, "api not amber yet")
            t.expectEqual(Tour.trialPermission(at("amber"), steps: today, waiting: true, shown: false), .wait,
                          "before its step: an answer would do nothing")
            t.expectEqual(Tour.trialPermission(at("allow", .skipped), steps: today, waiting: true, shown: false), .wait,
                          "skipped: it may resume")
            t.expectEqual(Tour.trialPermission(at("depths"), steps: today, waiting: true, shown: false), .stop)
            t.expectEqual(Tour.trialPermission(TourProgress(status: .finished), steps: today, waiting: true, shown: false), .stop)
        },

        TestCase("A side question to events and a question to LampMaster have the script's answers; nothing else does") { t in
            let script = DemoScript.standard
            t.expect(script.sideAnswer(for: "demo-events-03").contains("/api/v2/slots"), "events knows the calendar")
            t.expect(script.sideAnswer(for: "demo-docs-0001").hasPrefix("In the trial"), "another session: said plainly")
            t.expect(script.lampMasterAnswer.contains("api"), "LampMaster names who renamed it")
            t.expect(DemoScriptCheck.problems(script).isEmpty, "the answers hold nothing real")
        },

        TestCase("Every step points at something the trial draws: a row of the script, or a part of the panel") { t in
            let ids = Set(DemoScript.standard.sessions.map(\.id))
            for step in Tour.all() {
                if case .row(let id) = step.anchor { t.expect(ids.contains(id), "\(step.id) points at \(id), not in the script") }
            }
            let anchors = Dictionary(uniqueKeysWithValues: Tour.all().map { ($0.id, $0.anchor) })
            t.expectEqual(anchors["command"], .bar)
            t.expectEqual(anchors["away"], .panelMenu)
            t.expectEqual(anchors["allowance"], .allowance)
            t.expectEqual(anchors["lampmaster"], .lampMaster)
            t.expect(Tour.rings(["x", "demo-events-03"], .row(session: "demo-events-03")), "a row holding it is ringed")
            t.expect(!Tour.rings(["demo-api-00002"], .row(session: "demo-events-03")), "another row is not")
            t.expect(!Tour.rings(["demo-events-03"], .bar), "the bar is not a row")
        },

        TestCase("Every step's sentence fits the band's two lines in the narrow panel") { t in
            for step in Tour.all() {
                t.expect(step.text.count <= Tour.longestText, "\(step.id): \(step.text.count) characters")
            }
        },

        TestCase("A step moves on with its own gesture, and with nothing else") { t in
            var progress = TourProgress.start(today)
            t.expectEqual(progress.position(in: today)?.index, 1)
            progress = progress.after(.rowOpened(session: "demo-api-00002"), in: today)
            t.expectEqual(progress.stepId, "colours", "the wrong row does not count")
            progress = progress.after(.rowOpened(session: "demo-docs-0001"), in: today)
            t.expectEqual(progress.stepId, "amber")
            progress = progress.after(.rowOpened(session: "demo-api-00002"), in: today)
            t.expectEqual(progress.stepId, "allow")
            progress = progress.after(.permissionAnswered(session: "demo-docs-0001"), in: today)
            t.expectEqual(progress.stepId, "allow", "another session's answer is not this one")
            progress = progress.after(.permissionAnswered(session: "demo-api-00002"), in: today)
            t.expectEqual(progress.stepId, "depths")
            progress = progress.after(.planciaOpened(session: "demo-events-03"), in: today)
            t.expectEqual(progress.stepId, "depths", "a Plancia opened some other way is not the depths")
            progress = progress.after(.depthReachedPlancia, in: today)
            t.expectEqual(progress.stepId, "plancia")
            progress = progress.after(.planciaOpened(session: "demo-docs-0001"), in: today)
            t.expectEqual(progress.stepId, "plancia", "events, not another session")
            progress = progress.after(.planciaOpened(session: "demo-events-03"), in: today)
                .after(.barChose, in: today)
            t.expectEqual(progress.stepId, "squad")
            progress = progress.after(.sideQuestionAnswered(session: "demo-events-03"), in: today)
                .after(.allowanceInspected, in: today)
            t.expectEqual(progress.stepId, "focus")
            progress = progress.after(.focused, in: today).after(.awayToggled(on: true), in: today)
            t.expectEqual(progress.stepId, "away", "away is learnt by coming back")
            progress = progress.after(.awayToggled(on: false), in: today).after(.lampMasterAnswered, in: today)
            t.expectEqual(progress.stepId, "ask")
            progress = progress.after(.lampMasterAsked, in: today)
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
