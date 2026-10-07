import LampBoardCore
import Foundation
import TestKit

/// The first minute (U4): seven screens on the person's own sessions, and three
/// sample rows in the real panel for whoever has no session at hand.
enum WelcomeSuite {

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func facts(hooks: Bool = false, codex: Bool = false, row: Bool = false, accessibility: Bool = false,
                              helper: Bool = false, alerts: Bool = false) -> Welcome.Facts {
        Welcome.Facts(connected: hooks, codexPresent: codex, hasRow: row, accessibility: accessibility,
                      helperInstalled: helper, alertsOn: alerts)
    }

    static let suite = TestSuite("Welcome and samples", [

        TestCase("Seven screens, one idea and one action each") { t in
            t.expectEqual(Welcome.Step.allCases.map(\.title), [
                "See every agent at a glance", "Your first lamp", "Three colours to know", "One click and you are there",
                "Answer without changing window", "⌘K finds everything", "That's it",
            ])
            for step in Welcome.Step.allCases {
                t.expect(step.text.count <= 240, "\(step.title): \(step.text.count) characters")
            }
        },

        TestCase("Each screen's button does what is missing, and says Next once it is done") { t in
            t.expectEqual(Welcome.Step.welcome.action(facts()), .connect("Connect Claude Code"))
            t.expectEqual(Welcome.Step.welcome.action(facts(codex: true)), .connect("Connect Claude Code and Codex"),
                          "Codex is named only where it is installed")
            t.expectEqual(Welcome.Step.welcome.action(facts(hooks: true)), .next)
            t.expectEqual(Welcome.Step.firstLamp.action(facts(hooks: true)), .practice,
                          "no row yet: samples, or wait for a session to speak")
            t.expectEqual(Welcome.Step.firstLamp.action(facts(hooks: true, row: true)), .next)
            t.expectEqual(Welcome.Step.click.action(facts(row: true)), .grantAccessibility)
            t.expectEqual(Welcome.Step.answer.action(facts()), .installHelper)
            t.expectEqual(Welcome.Step.answer.action(facts(helper: true)), .next)
            t.expectEqual(Welcome.Step.done.action(facts()), .turnOnAlerts)
            t.expectEqual(Welcome.Step.done.action(facts(alerts: true)), .close)
        },

        TestCase("Three sample rows, marked as such, under a folder no project has") { t in
            let samples = Samples.sessions(since: t0, now: t0, seen: [])
            t.expectEqual(samples.map(\.workspace.name), ["api", "docs-site", "events"])
            t.expect(samples.allSatisfy { Samples.isSample($0.id) }, "every id says sample")
            t.expect(samples.allSatisfy { $0.workspace.path.hasPrefix(Samples.folder) }, "and every folder")
            t.expect(!Samples.isSample("e868ec7e-60cf-459d-b5f3-55fec2bdfa2f"), "a real id is not one")
        },

        TestCase("The colours play out: api works, then has an answer, then asks") { t in
            func api(_ seconds: Double) -> SessionStatus? {
                Samples.sessions(since: t0, now: t0.addingTimeInterval(seconds), seen: []).first { $0.workspace.name == "api" }?.status
            }
            t.expectEqual(api(1), .working)
            t.expectEqual(api(9), .ready)
            t.expectEqual(api(17), .awaiting)
            let seen = Samples.sessions(since: t0, now: t0.addingTimeInterval(30), seen: [Samples.id("docs-site")])
            t.expectEqual(seen.first { $0.workspace.name == "docs-site" }?.status, .idle, "read, it rests")
        },

        TestCase("Added to the column's state, never to the store's") { t in
            let real = SessionState(id: "real-1", status: .working, workspace: Workspace(path: "/home/dev/web"),
                                    updatedAt: t0, statusSince: t0)
            let state = TrafficLightState(sessions: ["real-1": real])
            let shown = state.adding(Samples.sessions(since: t0, now: t0, seen: []))
            t.expectEqual(shown.sessions.count, 4)
            t.expectEqual(state.sessions.count, 1, "the state itself is unchanged")
        },
    ])
}
