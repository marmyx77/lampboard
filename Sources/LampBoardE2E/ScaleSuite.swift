import LampBoardCore
import Foundation
import TestKit

/// Scale and realignment: what happens with many sessions, and what happens when
/// a session dies without saying so.
///
/// The hooks only report what happens, never what disappeared. The periodic
/// realignment is the only thing stopping the column from filling up with rows
/// that lead nowhere, and it is asynchronous: whether it works can only be
/// verified by waiting for it to happen.
enum ScaleSuite {

    static func suite(_ app: AppUnderTest) -> TestSuite {
        TestSuite("E2E · scale and realignment", [

            TestCase("a session alive on the filesystem gets adopted on its own") { a in
                let id = "e2e-adopted"
                app.writeLiveSession(
                    sessionId: id,
                    cwd: LifecycleSuite.workspace,
                    name: "project-alpha-7"
                )
                // A conversation behind it, because that is what a row stands
                // for: a process with nothing in it is refused at this door on
                // purpose (see the coverage suite).
                app.writeTranscript(
                    sessionId: id, cwd: LifecycleSuite.workspace, title: "Wire the release script"
                )
                // No hook for this session: it existed before the app started.
                // Without adoption it would stay invisible until the user did
                // something inside it.
                a.expect(
                    app.waitUntil { app.status(of: id) == "idle" },
                    "status: \(app.status(of: id))"
                )
            },

            TestCase("adoption does not overwrite what the hooks already know") { a in
                let id = "e2e-adopted"
                app.sendHook(HookPayloads.stop(sessionId: id, cwd: LifecycleSuite.workspace))
                a.expect(
                    app.waitUntil { app.status(of: id) == "ready" },
                    "premise: \(app.status(of: id))"
                )

                // The realignment runs every five seconds: if it adopted again, a
                // ready answer would turn red on its own.
                usleep(6_500_000)
                a.expectEqual(app.status(of: id), "ready", "status after the realignment")
            },

            TestCase("the column holds up with a couple of dozen sessions") { a in
                // The real scale measured: 22 distinct sessionIds across 12 windows.
                for index in 0..<22 {
                    app.sendHook(HookPayloads.userPromptSubmit(
                        sessionId: "e2e-bulk-\(index)", cwd: LifecycleSuite.workspace
                    ))
                }
                a.expect(
                    app.waitUntil {
                        let ids = app.sessions()?.sessions.map(\.id) ?? []
                        return ids.filter { $0.hasPrefix("e2e-bulk-") }.count == 22
                    },
                    "rows: \((app.sessions()?.sessions.filter { $0.id.hasPrefix("e2e-bulk-") }.count) ?? -1)"
                )
            },

            TestCase("a session whose process has died disappears on its own") { a in
                let id = "e2e-dead-process"
                app.sendHook(HookPayloads.stop(sessionId: id, cwd: LifecycleSuite.workspace))
                a.expect(
                    app.waitUntil { app.status(of: id) == "ready" },
                    "premise: \(app.status(of: id))"
                )

                // PID 999999: almost certainly doesn't exist. That's enough for
                // the realignment to stop finding the session among the live ones.
                //
                // The hooks only report what happens, never what disappeared:
                // without the realignment this row would stay clickable and lead
                // nowhere.
                app.removeLiveSessions()
                app.writeLiveSession(
                    sessionId: "e2e-alive-elsewhere",
                    cwd: LifecycleSuite.workspace,
                    pid: 999_999
                )
                app.writeLiveSession(
                    sessionId: "e2e-really-alive",
                    cwd: LifecycleSuite.workspace
                )
                app.writeTranscript(
                    sessionId: "e2e-really-alive", cwd: LifecycleSuite.workspace,
                    title: "Still going"
                )

                a.expect(
                    app.waitUntil(timeout: 15) { app.status(of: id) == "absent" },
                    "status: \(app.status(of: id))"
                )
                a.expectEqual(app.status(of: "e2e-alive-elsewhere"), "absent", "dead pid")
                a.expect(
                    app.waitUntil { app.status(of: "e2e-really-alive") == "idle" },
                    "the live session should have stayed"
                )
            },

            TestCase("the sessions come out sorted by urgency") { a in
                guard let sessions = app.sessions()?.sessions else {
                    a.fail("no response")
                    return
                }
                let ranks = sessions.compactMap {
                    SessionStatus(rawValue: $0.status)?.urgencyRank
                }
                a.expectEqual(ranks.count, sessions.count, "recognized states")
                a.expect(
                    ranks == ranks.sorted(),
                    "order not ascending by urgency: \(ranks)"
                )
            },
        ])
    }
}
