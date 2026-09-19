import LampBoardCore
import Foundation
import TestKit

/// Coverage: the sessions that exist and that the panel has to see.
///
/// This is the most serious defect to correct, because it is invisible. A wrong
/// traffic light gets noticed and you learn to distrust it; a row that isn't
/// there says nothing, and teaches you to trust an incomplete column.
enum CoverageSuite {

    static let secondWorkspace = "/tmp/lampboard-e2e/project-beta"
    static let terminalWorkspace = "/tmp/lampboard-e2e/project-terminal"

    static func suite(_ app: AppUnderTest) -> TestSuite {
        TestSuite("E2E · coverage", [

            // MARK: - 1.1 integrated-terminal sessions

            TestCase("a terminal-started session inside a workspace counts") { a in
                let id = "e2e-terminal"
                // `cli` is the entrypoint of `claude` launched by hand. If the cwd
                // sits inside a folder VS Code has open, the session runs in the
                // *integrated* terminal: same window, same project, same click
                // that brings it to the front.
                app.sendHook(
                    HookPayloads.userPromptSubmit(sessionId: id, cwd: terminalWorkspace),
                    entrypoint: "cli"
                )
                a.expect(
                    app.waitUntil { app.status(of: id) == "working" },
                    "status: \(app.status(of: id))"
                )
                // The endpoint says how the session was started: it is what tells
                // a click not to send the tab deep link to a session with no tab.
                a.expectEqual(app.session(id: id)?.entrypoint, "cli", "entrypoint published")
            },

            TestCase("a terminal session outside every workspace stays excluded") { a in
                let id = "e2e-terminal-outside"
                app.sendHook(
                    HookPayloads.userPromptSubmit(sessionId: id, cwd: "/tmp/no-workspace-here"),
                    entrypoint: "cli"
                )
                usleep(400_000)
                // The criterion is the folder, not how the session was started:
                // here the folder belongs to no window.
                a.expectEqual(app.status(of: id), "absent", "status")
            },

            // MARK: - 1.2 terminal rows (D25)

            // With the switch on, a folder nobody claims is a place too — but only
            // for a session whose live file names it: the file's cwd is the row's
            // folder, and a signal with no file behind it is still nothing.
            // Reported from use: a project showed two conversations where the
            // editor had one. Both processes were alive — VS Code had started a
            // second `claude` twenty-three seconds after the first and never
            // killed it — but only one of them had ever held a conversation. The
            // other had no transcript anywhere on the disk, and its row was a
            // line you could click into an empty window.
            TestCase("a session that has never said a word gets no row, and gets one the moment it does") { a in
                let id = "e2e-never-spoke"
                let folder = LifecycleSuite.workspace
                // Alive for certain: pid 1 answers EPERM to `kill(1, 0)`, which
                // the reader counts as alive.
                app.writeLiveSession(sessionId: id, cwd: folder, pid: 1)
                defer { app.removeLiveSessions() }

                // The event that says a process exists. It is not the event that
                // says something happened.
                app.sendHook(HookPayloads.sessionStart(sessionId: id, cwd: folder))

                a.expect(
                    app.holdsThroughTwoSweeps { app.session(id: id) == nil },
                    "a live process with no conversation behind it is not a row"
                )

                // And the first word it says brings it back, with no gesture from
                // anybody: the rule is about having nothing to show, not about
                // having been refused once.
                app.writeTranscript(sessionId: id, cwd: folder, title: "Wire the release script")
                defer {
                    try? FileManager.default.removeItem(
                        at: TranscriptLocator.candidateURL(sessionId: id, cwd: folder, home: app.home)
                    )
                }
                a.expect(
                    app.waitUntil { app.session(id: id) != nil },
                    "the row appears as soon as there is a conversation to open"
                )
            },

            TestCase("a terminal session in a folder nobody claims gets a row when told so") { a in
                a.expectEqual(app.runCommand(["terminal", "on"]).status, 0, "switch on")
                defer { app.runCommand(["terminal", "off"]) }
                let id = "e2e-terminal-row"
                let folder = "/tmp/e2e-terminal-home"
                // pid 1: alive for certain, owned by root — `kill(1, 0)` answers
                // EPERM, which the reader counts as alive — and a file name no
                // other case writes.
                app.writeLiveSession(sessionId: id, cwd: folder, entrypoint: "cli", pid: 1)
                // Where the hook fixture says the transcript is.
                let transcript = HookPayloads.transcriptPath(id)
                app.writeTranscript(sessionId: id, cwd: folder, title: "Wire the release script", at: transcript)
                defer {
                    app.removeLiveSessions()
                    try? FileManager.default.removeItem(atPath: transcript)
                }

                app.sendHook(
                    // The hook's cwd has moved (a `cd` in the session); the row stays
                    // on the file's folder.
                    HookPayloads.userPromptSubmit(sessionId: id, cwd: folder + "/deeper"),
                    entrypoint: "cli"
                )
                a.expect(app.waitUntil { app.status(of: id) == "working" }, "status: \(app.status(of: id))")
                let session = app.session(id: id)
                a.expectEqual(session?.origin, "terminal", "origin")
                a.expectEqual(session?.path, folder, "anchored on the file's folder, not the hook's cwd")
                a.expect(
                    app.waitUntil { app.session(id: id)?.title == "Wire the release script" },
                    "title read from the transcript: \(app.session(id: id)?.title ?? "nil")"
                )

                // `new` on a terminal row has no tab to open one in.
                if let slot = app.sessions()?.sessions.first(where: { $0.id == id })?.slot {
                    a.expectEqual(app.runCommand(["new", String(slot)]).status == 0, false, "new refused")
                }

                a.expectEqual(app.runCommand(["terminal", "off"]).status, 0, "switch off")
                a.expect(app.waitUntil { app.status(of: id) == "absent" }, "off takes its rows with it")
            },

            // MARK: - 1.3 row names

            // The name the user gives a row is what the panel and its readers
            // show; the folder underneath does not move, and neither does the
            // session's own name.
            TestCase("a renamed row keeps its folder and publishes the name") { a in
                let id = "e2e-renamed"
                app.sendHook(HookPayloads.userPromptSubmit(sessionId: id, cwd: secondWorkspace), entrypoint: "claude-vscode")
                a.expect(app.waitUntil { app.status(of: id) == "working" }, "status: \(app.status(of: id))")

                a.expectEqual(app.runCommand(["rename", secondWorkspace, "Second", "act"]).status, 0, "renamed")
                defer { app.runCommand(["rename", secondWorkspace]) }
                a.expect(
                    app.waitUntil { app.session(id: id)?.label == "Second act" },
                    "label: \(app.session(id: id)?.label ?? "nil")"
                )
                a.expectEqual(app.session(id: id)?.workspace, (secondWorkspace as NSString).lastPathComponent, "the folder underneath")

                a.expectEqual(app.runCommand(["rename", secondWorkspace]).status, 0, "restored")
                a.expect(
                    app.waitUntil { app.session(id: id)?.label == (secondWorkspace as NSString).lastPathComponent },
                    "back to the folder: \(app.session(id: id)?.label ?? "nil")"
                )
                a.expectEqual(app.runCommand(["rename", "relative/path", "x"]).status, 2, "a relative folder is refused")
            },

            TestCase("a terminal signal with no live file behind it is still nothing") { a in
                a.expectEqual(app.runCommand(["terminal", "on"]).status, 0, "switch on")
                defer { app.runCommand(["terminal", "off"]) }
                let id = "e2e-terminal-orphan"
                app.sendHook(
                    HookPayloads.userPromptSubmit(sessionId: id, cwd: "/tmp/e2e-terminal-orphan"),
                    entrypoint: "cli"
                )
                usleep(400_000)
                a.expectEqual(app.status(of: id), "absent", "no file, no row")

                // An unknown host is treated as local, and local means the file rule.
                let foreign = "e2e-terminal-foreign"
                app.sendHook(
                    HookPayloads.userPromptSubmit(sessionId: foreign, cwd: "/home/dev/x"),
                    entrypoint: "cli", host: "stranger"
                )
                usleep(400_000)
                a.expectEqual(app.status(of: foreign), "absent", "a forged host gets no local row either")
            },

            TestCase("an entrypoint never seen before is not discarded") { a in
                let id = "e2e-unknown-entrypoint"
                app.sendHook(
                    HookPayloads.userPromptSubmit(sessionId: id, cwd: secondWorkspace),
                    entrypoint: "claude-something-from-2027"
                )
                a.expect(
                    app.waitUntil { app.status(of: id) == "working" },
                    "status: \(app.status(of: id))"
                )
            },

            // MARK: - 1.2 subagent counter


            // A machine's hooks reach this one through the tunnel and say where
            // they ran. No local editor window claims `/home/…`, and without the
            // header the signal would be dropped for exactly that reason.
            TestCase("a signal from another machine gets a row on that machine") { a in
                let id = "e2e-remote-\(UUID().uuidString.prefix(8))"
                let cwd = "/home/dev/.notes"
                // The header is believed only for a machine this app was told
                // about: a host anyone on loopback could write does not get to
                // skip the gate that bounds every local signal.
                a.expectEqual(app.runCommand(["remote", "add", "node"]).status, 0, "host configured")
                defer { app.runCommand(["remote", "remove", "node"]) }
                usleep(300_000)
                a.expectEqual(
                    app.sendHook(HookPayloads.userPromptSubmit(sessionId: id, cwd: cwd), entrypoint: "cli", host: "node"),
                    204, "accepted"
                )
                usleep(300_000)
                guard let session = app.session(id: id) else {
                    return a.fail("the remote session got no row")
                }
                a.expectEqual(session.status, "working", "status")
                a.expectEqual(session.host, "node", "host")
                a.expectEqual(session.workspace, ".notes", "its own folder is the workspace")

                // The same signal without the header is a terminal session in a
                // folder no window here has open: no row, as before.
                let local = "e2e-remote-local-\(UUID().uuidString.prefix(8))"
                app.sendHook(HookPayloads.userPromptSubmit(sessionId: local, cwd: cwd), entrypoint: "cli")
                usleep(300_000)
                a.expectEqual(app.status(of: local), "absent", "no host, no row")

                // A host nobody configured is a header, not a machine.
                let forged = "e2e-remote-forged-\(UUID().uuidString.prefix(8))"
                app.sendHook(HookPayloads.userPromptSubmit(sessionId: forged, cwd: cwd), entrypoint: "cli", host: "stranger")
                usleep(300_000)
                a.expectEqual(app.status(of: forged), "absent", "unknown host, no row")
            },
            TestCase("a subagent starting after the Stop turns the row blue") { a in
                // It arrives after the parent's Stop, so it is a background agent:
                // the session has stopped and is waiting for it — not working (D22).
                let id = "e2e-subagent"
                app.sendHook(HookPayloads.stop(sessionId: id, cwd: secondWorkspace))
                a.expect(
                    app.waitUntil { app.status(of: id) == "ready" },
                    "premise: \(app.status(of: id))"
                )

                app.sendHook(HookPayloads.subagentStart(
                    sessionId: id, cwd: secondWorkspace, agentId: "agent-1"
                ))
                a.expect(
                    app.waitUntil { app.status(of: id) == "waiting" },
                    "status: \(app.status(of: id))"
                )
                a.expectEqual(app.session(id: id)?.activeSubagents, 1, "counter")
            },

            TestCase("two subagents count two") { a in
                let id = "e2e-subagent"
                app.sendHook(HookPayloads.subagentStart(
                    sessionId: id, cwd: secondWorkspace, agentId: "agent-2"
                ))
                a.expect(
                    app.waitUntil { app.session(id: id)?.activeSubagents == 2 },
                    "counter: \(app.session(id: id)?.activeSubagents ?? -1)"
                )
            },

            TestCase("with a subagent still alive the session stays blue, not green") { a in
                let id = "e2e-subagent"
                app.sendHook(HookPayloads.subagentStop(
                    sessionId: id, cwd: secondWorkspace, agentId: "agent-1"
                ))
                a.expect(
                    app.waitUntil { app.session(id: id)?.activeSubagents == 1 },
                    "counter: \(app.session(id: id)?.activeSubagents ?? -1)"
                )
                // The parent's turn isn't over: no `Stop` has arrived and an agent
                // is still working.
                a.expectEqual(app.status(of: id), "waiting", "status")
            },

            TestCase("the turn ending with an agent alive is a wait, not a finish") { a in
                let id = "e2e-subagent"
                // This is the background-agent case: the parent turn returns
                // control — `Stop` — while the agents keep going for tens of
                // minutes. Taking that `Stop` literally would paint it green;
                // calling it "working" would be the other half-truth (D22).
                app.sendHook(HookPayloads.stop(sessionId: id, cwd: secondWorkspace))
                usleep(400_000)
                a.expectEqual(app.status(of: id), "waiting", "status")
                a.expectEqual(app.session(id: id)?.activeSubagents, 1, "counter")
            },

            TestCase("when the last agent finishes the green set aside resurfaces") { a in
                let id = "e2e-subagent"
                app.sendHook(HookPayloads.subagentStop(
                    sessionId: id, cwd: secondWorkspace, agentId: "agent-2"
                ))
                // Nobody had to remember the green: the displayed state is
                // derived, so the earlier `Stop` comes back on its own.
                a.expect(
                    app.waitUntil { app.status(of: id) == "ready" },
                    "status: \(app.status(of: id))"
                )
                a.expectEqual(app.session(id: id)?.activeSubagents, 0, "counter")
            },

            TestCase("a stop with no start does not push the counter below zero") { a in
                let id = "e2e-orphan-subagent"
                app.sendHook(HookPayloads.stop(sessionId: id, cwd: secondWorkspace))
                a.expect(
                    app.waitUntil { app.status(of: id) == "ready" },
                    "premise: \(app.status(of: id))"
                )

                // It really happens: the app starts mid-turn and only sees the end.
                app.sendHook(HookPayloads.subagentStop(
                    sessionId: id, cwd: secondWorkspace, agentId: "ghost"
                ))
                usleep(400_000)
                a.expectEqual(app.session(id: id)?.activeSubagents, 0, "counter")
                a.expectEqual(app.status(of: id), "ready", "status")
            },

            TestCase("a new prompt clears a counter left hanging") { a in
                let id = "e2e-hanging-subagent"
                // Two starts and no stops: that's what's left if the app is
                // restarted while agents are running.
                app.sendHook(HookPayloads.subagentStart(
                    sessionId: id, cwd: secondWorkspace, agentId: "lost-1"
                ))
                app.sendHook(HookPayloads.subagentStart(
                    sessionId: id, cwd: secondWorkspace, agentId: "lost-2"
                ))
                a.expect(
                    app.waitUntil { app.session(id: id)?.activeSubagents == 2 },
                    "premise: \(app.session(id: id)?.activeSubagents ?? -1)"
                )

                app.sendHook(HookPayloads.userPromptSubmit(sessionId: id, cwd: secondWorkspace))
                a.expect(
                    app.waitUntil { app.session(id: id)?.activeSubagents == 0 },
                    "counter: \(app.session(id: id)?.activeSubagents ?? -1)"
                )
            },

            TestCase("a subagent creates the row of a session never seen before") { a in
                let id = "e2e-subagent-discovery"
                app.sendHook(HookPayloads.subagentStart(
                    sessionId: id, cwd: secondWorkspace, agentId: "first"
                ))
                a.expect(
                    app.waitUntil { app.status(of: id) == "working" },
                    "status: \(app.status(of: id))"
                )
            },

            TestCase("a stop does not materialize a row out of nothing") { a in
                let id = "e2e-subagent-never-seen"
                app.sendHook(HookPayloads.subagentStop(
                    sessionId: id, cwd: secondWorkspace, agentId: "end-only"
                ))
                usleep(400_000)
                // Inventing a state out of its own conclusion is the simplest way
                // to fill the column with rows nobody needs.
                a.expectEqual(app.status(of: id), "absent", "status")
            },

            TestCase("events inside a subagent do not move the traffic light") { a in
                let id = "e2e-subagent-internal"
                app.sendHook(HookPayloads.stop(sessionId: id, cwd: secondWorkspace))
                a.expect(
                    app.waitUntil { app.status(of: id) == "ready" },
                    "premise: \(app.status(of: id))"
                )

                // A tool call *inside* a subagent carries `agent_id`: it is work
                // happening under the parent's turn and does not describe it.
                app.sendHook(HookPayloads.toolUseInsideSubagent(
                    sessionId: id, cwd: secondWorkspace, agentId: "agent-9"
                ))
                usleep(400_000)
                a.expectEqual(app.status(of: id), "ready", "status")
                a.expectEqual(app.session(id: id)?.activeSubagents, 0, "counter")
            },

            // The diagnosis is run when something already seems wrong, so a
            // failure it invents is worse than one it misses. This one was
            // invented: with the panel running, `SignalServer.start()` returned
            // before its listener had failed on the taken port, the probe reached
            // the panel instead, and the test announced "the signal never reached
            // the handler" on a chain that was working.
            TestCase("the self-test does not invent a failure when the panel is running") { a in
                let result = app.runCommand(["selftest", "--port", String(app.port)])

                a.expect(
                    !result.output.contains("the signal never reached the handler"),
                    "phantom failure reported — output:\n\(result.output)"
                )
                a.expect(
                    result.output.contains("already listening"),
                    "it should say who holds the port — output:\n\(result.output)"
                )
                a.expect(
                    result.output.contains("accepts signals (HTTP 204)"),
                    "and confirm the running panel answers — output:\n\(result.output)"
                )
                a.expect(
                    !result.output.contains("the server won't start"),
                    "it should not try to bind a port it knows is taken — output:\n\(result.output)"
                )
            },

            // The other half of the same promise: what it cannot verify, it says
            // it did not verify. Silence there reads as a pass.
            TestCase("the self-test still reports the environment it can check") { a in
                let result = app.runCommand(["selftest", "--port", String(app.port)])

                a.expect(
                    result.output.contains("hooks registered")
                        || result.output.contains("no hooks registered"),
                    "the hooks are reported either way — output:\n\(result.output)"
                )
                a.expect(
                    result.output.contains("is not run here"),
                    "and the loop test is declared skipped, not passed — output:\n\(result.output)"
                )
            },
        ])
    }
}
