import LampBoardCore
import Foundation
import TestKit

/// The lifecycle of a session, walked from the outside.
///
/// The state machine itself is already covered by the unit tests, which are
/// faster and more precise. What is verified here on top of that is the **chain**:
/// that the JSON arrives, gets decoded, crosses the workspace resolver, moves the
/// reducer and reappears in the snapshot. Every joint of that chain is a place
/// where a green unit test can coexist with a broken product.
enum LifecycleSuite {

    /// The workspace these cases use. It has to exist on the fake filesystem as a
    /// lock's folder, otherwise the resolver — quite rightly — discards it.
    static let workspace = "/tmp/lampboard-e2e/project-alpha"

    static func suite(_ app: AppUnderTest) -> TestSuite {
        TestSuite("E2E · lifecycle", [

            TestCase("an unknown session does not appear out of nowhere") { a in
                app.sendHook(HookPayloads.userPromptSubmit(
                    sessionId: "e2e-outside", cwd: "/tmp/outside-every-workspace"
                ))
                // No lock contains that folder: the row must not exist.
                a.expectEqual(app.status(of: "e2e-outside"), "absent", "status")
            },

            TestCase("prompt submitted → the session works") { a in
                let id = "e2e-cycle"
                app.sendHook(HookPayloads.userPromptSubmit(sessionId: id, cwd: workspace))
                a.expect(
                    app.waitUntil { app.status(of: id) == "working" },
                    "status: \(app.status(of: id))"
                )
            },

            TestCase("turn finished → answer ready") { a in
                let id = "e2e-cycle"
                app.sendHook(HookPayloads.stop(
                    sessionId: id, cwd: workspace, message: "I've finished the work."
                ))
                a.expect(
                    app.waitUntil { app.status(of: id) == "ready" },
                    "status: \(app.status(of: id))"
                )
                a.expectEqual(
                    app.session(id: id)?.lastMessage, "I've finished the work.", "preview"
                )
            },

            TestCase("a late PostToolUse does not downgrade the green") { a in
                let id = "e2e-cycle"
                app.sendHook([
                    "session_id": id,
                    "hook_event_name": "PostToolUse",
                    "cwd": workspace,
                ])
                // There is no moment at which to expect a change: we allow time
                // for it to *be able* to go wrong, then check.
                usleep(400_000)
                a.expectEqual(app.status(of: id), "ready", "status")
            },

            TestCase("a new prompt puts the session back to work") { a in
                let id = "e2e-cycle"
                app.sendHook(HookPayloads.userPromptSubmit(sessionId: id, cwd: workspace))
                a.expect(
                    app.waitUntil { app.status(of: id) == "working" },
                    "status: \(app.status(of: id))"
                )
            },

            TestCase("permission request → awaiting") { a in
                let id = "e2e-permission"
                app.sendHook(HookPayloads.userPromptSubmit(sessionId: id, cwd: workspace))
                app.sendHook(HookPayloads.notification(
                    sessionId: id, cwd: workspace, kind: "permission_prompt"
                ))
                a.expect(
                    app.waitUntil { app.status(of: id) == "awaiting" },
                    "status: \(app.status(of: id))"
                )
            },

            TestCase("an MCP server's dialog blocks like a permission does") { a in
                let id = "e2e-mcp"
                app.sendHook(HookPayloads.notification(
                    sessionId: id, cwd: workspace, kind: "elicitation_dialog"
                ))
                a.expect(
                    app.waitUntil { app.status(of: id) == "awaiting" },
                    "status: \(app.status(of: id))"
                )
            },

            TestCase("the inactivity timer does not invent an answer") { a in
                let id = "e2e-idle"
                app.sendHook(HookPayloads.notification(
                    sessionId: id, cwd: workspace, kind: "idle_prompt"
                ))
                // It has to create the row — that proves the session exists — but
                // idle, not green: nothing arrived to be read.
                a.expect(
                    app.waitUntil { app.status(of: id) == "idle" },
                    "status: \(app.status(of: id))"
                )
            },

            TestCase("turn cut short by an API error → failed, not green") { a in
                let id = "e2e-failure"
                app.sendHook(HookPayloads.userPromptSubmit(sessionId: id, cwd: workspace))
                app.sendHook(HookPayloads.stopFailure(
                    sessionId: id, cwd: workspace, errorType: "rate_limit"
                ))
                a.expect(
                    app.waitUntil { app.status(of: id) == "failed" },
                    "status: \(app.status(of: id))"
                )
                a.expectEqual(app.session(id: id)?.failureReason, "rate_limit", "reason")
            },

            TestCase("a truncated answer stays readable, therefore green") { a in
                let id = "e2e-truncated"
                app.sendHook(HookPayloads.stopFailure(
                    sessionId: id, cwd: workspace, errorType: "max_output_tokens"
                ))
                a.expect(
                    app.waitUntil { app.status(of: id) == "ready" },
                    "status: \(app.status(of: id))"
                )
            },

            TestCase("an unknown error falls back to unknown, it doesn't vanish") { a in
                let id = "e2e-unknown"
                app.sendHook(HookPayloads.stopFailure(
                    sessionId: id, cwd: workspace, errorType: "something_new_2027"
                ))
                a.expect(
                    app.waitUntil { app.status(of: id) == "failed" },
                    "status: \(app.status(of: id))"
                )
                a.expectEqual(app.session(id: id)?.failureReason, "unknown", "reason")
            },

            TestCase("context compaction does not clear the yellow") { a in
                let id = "e2e-compaction"
                app.sendHook(HookPayloads.userPromptSubmit(sessionId: id, cwd: workspace))
                a.expect(
                    app.waitUntil { app.status(of: id) == "working" },
                    "premise: \(app.status(of: id))"
                )

                app.sendHook(HookPayloads.sessionStart(
                    sessionId: id, cwd: workspace, source: "compact"
                ))
                usleep(400_000)
                // `SessionStart` with `source: compact` fires **mid-turn**.
                // Treating it as a startup would clear a session that is working.
                a.expectEqual(app.status(of: id), "working", "status")
            },

            TestCase("a session start with a conversation behind it puts it at rest") { a in
                let id = "e2e-startup"
                // The transcript first, because that is the order the world
                // happens in for the case this covers: a session being resumed
                // has its conversation on disk before it announces itself. A
                // start with nothing behind it is refused, which the coverage
                // suite covers and this one deliberately does not repeat.
                let transcript = HookPayloads.transcriptPath(id)
                app.writeTranscript(sessionId: id, cwd: workspace, title: "Picking it up again", at: transcript)
                defer { try? FileManager.default.removeItem(atPath: transcript) }

                app.sendHook(HookPayloads.sessionStart(
                    sessionId: id, cwd: workspace, source: "startup"
                ))
                a.expect(
                    app.waitUntil { app.status(of: id) == "idle" },
                    "status: \(app.status(of: id))"
                )
            },

            TestCase("the session ending removes the row") { a in
                let id = "e2e-end"
                app.sendHook(HookPayloads.stop(sessionId: id, cwd: workspace))
                a.expect(
                    app.waitUntil { app.status(of: id) == "ready" },
                    "premise: \(app.status(of: id))"
                )

                app.sendHook(HookPayloads.sessionEnd(sessionId: id, cwd: workspace))
                a.expect(
                    app.waitUntil { app.status(of: id) == "absent" },
                    "status: \(app.status(of: id))"
                )
            },

            TestCase("the response dates are re-readable ISO 8601") { a in
                guard let response = app.sessions(), let first = response.sessions.first else {
                    a.fail("no session to inspect")
                    return
                }
                // If the date encoding were wrong the decoder would already have
                // failed; here we check the value is sensible and not a 1970 born
                // from a misread timestamp.
                a.expect(
                    first.updatedAt.timeIntervalSince1970 > 1_700_000_000,
                    "implausible date: \(first.updatedAt)"
                )
            },
        ])
    }
}
