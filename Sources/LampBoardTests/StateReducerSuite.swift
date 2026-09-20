import LampBoardCore
import Foundation
import TestKit

enum StateReducerSuite {

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private static let workspace = Workspace(path: "/Users/dev/Development/lampboard")
    private static let sessionId = "sess-1"

    // MARK: - Helpers

    private static func signal(
        _ event: HookEventKind,
        notification: NotificationKind? = nil,
        agentId: String? = nil,
        entrypoint: String? = "claude-vscode",
        message: String? = nil,
        git: GitIdentity? = nil
    ) -> HookSignal {
        HookSignal(
            sessionId: sessionId,
            event: event,
            cwd: workspace.path,
            notificationKind: notification,
            agentId: agentId,
            entrypoint: entrypoint,
            lastAssistantMessage: message,
            git: git
        )
    }

    private static func apply(
        _ signals: [HookSignal],
        to state: TrafficLightState = .empty,
        at date: Date? = nil
    ) -> TrafficLightState {
        signals.reduce(state) { partial, signal in
            StateReducer.reduce(
                partial,
                action: .signal(signal, workspace: workspace),
                now: date ?? t0
            )
        }
    }

    private static func status(_ state: TrafficLightState) -> SessionStatus? {
        state.sessions[sessionId]?.status
    }

    // MARK: - Suite

    static let suite = TestSuite("Traffic light state machine", [

        // MARK: Basic transitions

        TestCase("SessionStart creates a red traffic light") { t in
            let state = apply([signal(.sessionStart)])
            t.expectEqual(status(state), .idle)
            t.expectEqual(state.sessions[sessionId]?.workspace, workspace, "workspace")
        },

        // The entrypoint decides whether a click may follow with the tab deep
        // link: the extension hosts `claude-vscode` sessions, nobody hosts a
        // `cli` one. It is a fact about the session, not about the event, so it
        // is remembered once and never cleared by a signal that lacks it.
        TestCase("The entrypoint is remembered and survives a signal without one") { t in
            let state = apply([
                signal(.sessionStart, entrypoint: "cli"),
                signal(.userPromptSubmit, entrypoint: nil),
                signal(.stop, entrypoint: nil),
            ])
            t.expectEqual(state.sessions[sessionId]?.entrypoint, "cli", "entrypoint")
            t.expectEqual(status(state), .ready, "the transitions were not disturbed")
        },

        // MARK: Terminal rows

        // The origin is whatever the last resolution said: a session in a folder
        // nobody claims is a terminal row; when that folder is opened in an
        // editor, its next signal makes it an editor row — it moved into a window.
        TestCase("The origin follows the latest resolution") { t in
            let terminal = StateReducer.reduce(
                .empty, action: .signal(signal(.sessionStart), workspace: workspace, origin: .terminal), now: t0
            )
            t.expectEqual(terminal.sessions[sessionId]?.origin, .terminal, "born in a terminal")

            let editor = StateReducer.reduce(
                terminal, action: .signal(signal(.userPromptSubmit), workspace: workspace), now: t0
            )
            t.expectEqual(editor.sessions[sessionId]?.origin, .editor, "moved into a window")
            t.expectEqual(status(editor), .working, "the transition happened as well")
        },

        TestCase("A title is remembered, and only for a session that exists") { t in
            let state = apply([signal(.sessionStart), signal(.userPromptSubmit)])
            let titled = StateReducer.reduce(
                state, action: .remember(sessionId: sessionId, title: "Wire the release script"), now: t0
            )
            t.expectEqual(titled.sessions[sessionId]?.title, "Wire the release script", "title")

            let after = StateReducer.reduce(titled, action: .signal(signal(.stop), workspace: workspace), now: t0)
            t.expectEqual(after.sessions[sessionId]?.title, "Wire the release script", "survives a signal")

            let stranger = StateReducer.reduce(
                state, action: .remember(sessionId: "nobody", title: "x"), now: t0
            )
            t.expectEqual(stranger, state, "an unknown session is not created by its title")
        },

        TestCase("Forgetting an origin removes those rows and no other") { t in
            let both = StateReducer.reduce(
                apply([signal(.sessionStart)]),
                action: .signal(
                    HookSignal(sessionId: "term-1", event: .sessionStart, cwd: "/Users/dev"),
                    workspace: Workspace(path: "/Users/dev"), origin: .terminal
                ),
                now: t0
            )
            t.expectEqual(both.sessions.count, 2, "two rows")

            let kept = StateReducer.reduce(both, action: .forget(origin: .terminal), now: t0)
            t.expectEqual(kept.sessions.count, 1, "one left")
            t.expectNotNil(kept.sessions[sessionId], "the editor row stays")
        },

        // The folder of a session started in `~` is a username: a terminal row
        // is named by its conversation, once it has a title, and only while it is
        // alone — one name for three conversations lies about two of them.
        TestCase("A terminal row is named by its title, an editor row by its folder") { t in
            func session(_ id: String, origin: SessionOrigin, title: String?) -> SessionState {
                SessionState(
                    id: id, status: .idle, workspace: Workspace(path: "/Users/dev"),
                    updatedAt: t0, statusSince: t0, origin: origin, title: title
                )
            }
            t.expectEqual(session("a", origin: .terminal, title: "Wire it").displayName, "Wire it", "terminal, titled")
            t.expectEqual(session("a", origin: .terminal, title: nil).displayName, "dev", "terminal, no title yet")
            t.expectEqual(session("a", origin: .editor, title: "Wire it").displayName, "dev", "editor rows keep the folder")

            let one = TrafficLightState(sessions: ["a": session("a", origin: .terminal, title: "Wire it")])
            let rows = ColumnLayout.render(one, options: ColumnOptions()).rows
            t.expectEqual(rows.first?.displayName, "Wire it", "a row of one")
            t.expect(rows.first?.isTerminal == true, "and it says what it is")

            let two = TrafficLightState(sessions: [
                "a": session("a", origin: .terminal, title: "Wire it"),
                "b": session("b", origin: .terminal, title: "Other"),
            ])
            t.expectEqual(
                ColumnLayout.render(two, options: ColumnOptions()).rows.first?.displayName, "dev",
                "a row of two is the folder"
            )
        },

        TestCase("UserPromptSubmit goes to yellow") { t in
            t.expectEqual(status(apply([signal(.sessionStart), signal(.userPromptSubmit)])), .working)
        },

        TestCase("PreToolUse goes to yellow") { t in
            t.expectEqual(status(apply([signal(.preToolUse)])), .working)
        },

        TestCase("Stop goes to green and stores the preview") { t in
            let state = apply([signal(.userPromptSubmit), signal(.stop, message: "Done.")])
            t.expectEqual(status(state), .ready)
            t.expectEqual(state.sessions[sessionId]?.lastMessage, "Done.", "preview")
        },

        TestCase("A permission request goes to blinking amber") { t in
            let state = apply([
                signal(.userPromptSubmit),
                signal(.notification, notification: .permissionPrompt),
            ])
            t.expectEqual(status(state), .awaiting)
            t.expectEqual(status(state)?.shouldBlink, true, "must blink")
        },

        // This event's behavior changed: it used to go green, which amounted to
        // announcing an answer that never arrived. The full cases live in
        // ReducerFixesSuite; what remains here is the guard against a return to
        // the old behavior.
        TestCase("A turn interrupted by an API error does not go green") { t in
            t.expectEqual(status(apply([signal(.userPromptSubmit), signal(.stopFailure)])), .failed)
        },

        TestCase("SessionEnd removes the traffic light") { t in
            let started = apply([signal(.userPromptSubmit)])
            t.expectEqual(started.sessions.count, 1, "before the close")
            t.expectEqual(apply([signal(.sessionEnd)], to: started).sessions.count, 0, "after")
        },

        TestCase("A notification with no subtype changes nothing") { t in
            let state = apply([signal(.stop), signal(.notification, notification: nil)])
            t.expectEqual(status(state), .ready)
        },

        TestCase("A long preview gets truncated") { t in
            let state = apply([signal(.stop, message: String(repeating: "word ", count: 100))])
            guard let preview = state.sessions[sessionId]?.lastMessage else {
                return t.fail("preview missing")
            }
            t.expect(preview.count <= 141, "preview of \(preview.count) characters, expected ≤ 141")
            t.expect(preview.hasSuffix("…"), "must end with the ellipsis")
        },

        TestCase("The preview becomes a single line") { t in
            let state = apply([signal(.stop, message: "first line\nsecond   line")])
            t.expectEqual(state.sessions[sessionId]?.lastMessage, "first line second line")
        },

        // MARK: Filters

        TestCase("Ignores subagent signals") { t in
            let state = apply([signal(.sessionStart), signal(.stop, agentId: "agent_01")])
            t.expectEqual(status(state), .idle)
        },

        TestCase("Accepts integrated-terminal sessions") { t in
            // The criterion is no longer the entrypoint but the folder: `claude`
            // launched in VS Code's terminal sits in the same window and deserves
            // the same traffic light.
            t.expectEqual(apply([signal(.stop, entrypoint: "cli")]).sessions.count, 1)
        },

        TestCase("Ignores non-interactive sessions") { t in
            t.expectEqual(apply([signal(.stop, entrypoint: "sdk")]).sessions.count, 0)
        },

        TestCase("Ignores signals with no workspace") { t in
            let state = StateReducer.reduce(
                .empty, action: .signal(signal(.stop), workspace: nil), now: t0
            )
            t.expectEqual(state.sessions.count, 0)
        },

        // MARK: Protecting the unread states

        // The real case: a late PostToolUse arrives after the Stop.
        TestCase("A late PostToolUse does not clear the green") { t in
            t.expectEqual(status(apply([signal(.stop), signal(.postToolUse)])), .ready)
        },

        TestCase("A late PreToolUse does not clear the amber") { t in
            let state = apply([
                signal(.notification, notification: .permissionPrompt),
                signal(.preToolUse),
            ])
            t.expectEqual(status(state), .awaiting)
        },

        // Measured on 20 September 2026 and it is why `PostToolUseFailure` is
        // registered at all: Claude Code emits `PostToolUse` **or** this one, never
        // both, so a tool that was permitted and then failed produced neither the
        // proof nor the release. Granting a permission for a command that exits
        // non-zero left the row amber — the same stuck amber the `PostToolUse`
        // exception was written to end, surviving in the case nobody had tested.
        TestCase("A permitted tool that fails still clears the amber") { t in
            let state = apply([
                signal(.notification, notification: .permissionPrompt),
                signal(.postToolUseFailure),
            ])
            t.expectEqual(status(state), .working)
        },

        // The other half of the same measurement. A tool the sandbox **blocked**
        // emits neither event, so nothing releases the amber — which is right:
        // nothing ran, so nothing was granted. `PostToolBatch` would have fired
        // there, which is exactly why it is not registered.
        TestCase("A tool that never ran leaves the amber where it is") { t in
            let state = apply([
                signal(.notification, notification: .permissionPrompt),
                signal(.preToolUse),
            ])
            t.expectEqual(status(state), .awaiting)
        },

        TestCase("A new prompt restarts from yellow even after green") { t in
            t.expectEqual(status(apply([signal(.stop), signal(.userPromptSubmit)])), .working)
        },

        TestCase("Green can move to amber") { t in
            let state = apply([
                signal(.stop),
                signal(.notification, notification: .permissionPrompt),
            ])
            t.expectEqual(status(state), .awaiting)
        },

        // MARK: markSeen

        TestCase("markSeen clears the green") { t in
            let state = StateReducer.reduce(
                apply([signal(.stop)]), action: .markSeen(sessionId: sessionId), now: t0
            )
            t.expectEqual(status(state), .idle)
        },

        TestCase("markSeen clears the amber") { t in
            let state = StateReducer.reduce(
                apply([signal(.notification, notification: .permissionPrompt)]),
                action: .markSeen(sessionId: sessionId),
                now: t0
            )
            t.expectEqual(status(state), .idle)
        },

        TestCase("markSeen does not stop a session that is working") { t in
            let state = StateReducer.reduce(
                apply([signal(.userPromptSubmit)]),
                action: .markSeen(sessionId: sessionId),
                now: t0
            )
            t.expectEqual(status(state), .working)
        },

        TestCase("markSeen on a nonexistent session breaks nothing") { t in
            let state = StateReducer.reduce(.empty, action: .markSeen(sessionId: "x"), now: t0)
            t.expectEqual(state.sessions.count, 0)
        },

        // The row label shows `updatedAt`: if the click updated it, a session
        // idle for days would jump to "now" just for having been looked at.
        TestCase("markSeen does not alter the time of the last activity") { t in
            let state = apply([signal(.stop)], at: t0)
            let threeDaysLater = t0.addingTimeInterval(3 * 86_400)

            let seen = StateReducer.reduce(
                state, action: .markSeen(sessionId: sessionId), now: threeDaysLater
            )

            t.expectEqual(seen.sessions[sessionId]?.updatedAt, t0, "updatedAt")
            t.expectEqual(seen.sessions[sessionId]?.statusSince, threeDaysLater, "statusSince")
            t.expectEqual(seen.sessions[sessionId]?.status, .idle, "status")
        },

        // A deliberate consequence: seeing a session does not save it from pruning.
        TestCase("A seen but inactive session stays prunable") { t in
            let state = apply([signal(.stop)], at: t0)
            let later = t0.addingTimeInterval(AppConfig.sessionStaleAfter + 1)
            let seen = StateReducer.reduce(state, action: .markSeen(sessionId: sessionId), now: later)

            t.expectEqual(StateReducer.reduce(seen, action: .prune(), now: later).sessions.count, 0)
        },

        // MARK: State stopwatch

        TestCase("The stopwatch does not reset on repeated signals") { t in
            var state = apply([signal(.preToolUse)], at: t0)
            state = apply([signal(.preToolUse)], to: state, at: t0.addingTimeInterval(30))

            t.expectEqual(state.sessions[sessionId]?.statusSince, t0, "statusSince")
            t.expectEqual(state.sessions[sessionId]?.updatedAt, t0.addingTimeInterval(30), "updatedAt")
            t.expectEqual(
                state.sessions[sessionId]?.statusDuration(at: t0.addingTimeInterval(30)), 30, "duration"
            )
        },

        TestCase("The stopwatch restarts when the state changes") { t in
            var state = apply([signal(.preToolUse)], at: t0)
            state = apply([signal(.stop)], to: state, at: t0.addingTimeInterval(30))
            t.expectEqual(state.sessions[sessionId]?.statusSince, t0.addingTimeInterval(30))
        },

        // MARK: Prune

        TestCase("Prune removes the sessions quiet for too long") { t in
            let state = apply([signal(.stop)], at: t0)
            let later = t0.addingTimeInterval(AppConfig.sessionStaleAfter + 1)
            t.expectEqual(StateReducer.reduce(state, action: .prune(), now: later).sessions.count, 0)
        },

        // The unconditional exemption for `working` was removed: it made every
        // turn interrupted with Esc immortal, because in that case `Stop` doesn't
        // fire and no other hook covers it. The threshold now applies to everyone.
        TestCase("A turn that still has recent signals survives") { t in
            let state = apply([signal(.preToolUse)], at: t0)
            let soon = t0.addingTimeInterval(AppConfig.sessionStaleAfter - 60)
            t.expectEqual(StateReducer.reduce(state, action: .prune(), now: soon).sessions.count, 1)
        },

        TestCase("Reset empties everything") { t in
            let state = apply([signal(.stop)])
            t.expectEqual(StateReducer.reduce(state, action: .reset, now: t0).sessions.count, 0)
        },

        // MARK: Immutability

        TestCase("The reducer does not mutate the starting state") { t in
            let before = apply([signal(.userPromptSubmit)])
            let snapshot = before

            _ = StateReducer.reduce(
                before, action: .signal(signal(.stop), workspace: workspace), now: t0
            )

            t.expect(before == snapshot, "the starting state changed")
            t.expectEqual(status(before), .working, "original state")
        },

        // MARK: - The session's git identity, through the reducer

        TestCase("A signal carrying a repository puts it on the session") { t in
            let state = apply([
                signal(.userPromptSubmit),
                signal(.stop, git: GitIdentity(repo: "app", branch: "main")),
            ])
            t.expectEqual(state.sessions[sessionId]?.git?.repo, "app", "repository")
            t.expectEqual(state.sessions[sessionId]?.git?.branch, "main", "branch")
            // A copy of a signal must lose nothing but the reviewer. This compares
            // whole signals rather than named fields, so it also covers a field
            // nobody has written yet — `git` was lost exactly here, silently.
            let full = HookSignal(
                sessionId: "s", event: .stop, cwd: "/tmp/x",
                transcriptPath: nil, host: nil, harness: .claudeCode,
                git: GitIdentity(repo: "app", branch: "main", isWorktree: true)
            )
            t.expectEqual(full.withApprovalReviewer(nil), full, "a copy dropped a field")
        },
    ])
}
