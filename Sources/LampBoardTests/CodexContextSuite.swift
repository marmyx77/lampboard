import Foundation
import LampBoardCore
import TestKit

/// Reading a Codex rollout: the context window, the plan allowance, and the
/// rules that keep both honest.
///
/// The fixtures follow the shape of a real rollout, recorded from Codex 0.151.0
/// while this was written, with the paths and identifiers replaced. The numbers
/// are the ones that were actually there — 16,146 in a 258,400 window against
/// 32,187 cumulative — because the gap between those two figures is the whole
/// reason one of them is the wrong answer.
enum CodexContextSuite {

    /// A fixed moment, so the cases about transitions do not depend on the clock.
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func tokenCount(
        last: Int, total: Int, window: Int, at: String, percent: Double = 0.0
    ) -> String {
        """
        {"timestamp":"\(at)","type":"event_msg","payload":{"type":"token_count",\
        "info":{"total_token_usage":{"input_tokens":\(total),"cached_input_tokens":0,\
        "output_tokens":93,"total_tokens":\(total)},\
        "last_token_usage":{"input_tokens":\(last),"cached_input_tokens":15104,\
        "output_tokens":14,"total_tokens":\(last)},\
        "model_context_window":\(window)},\
        "rate_limits":{"limit_id":"codex","primary":{"used_percent":\(percent),\
        "window_minutes":10080,"resets_at":1788643990},"plan_type":"prolite"}}}
        """
    }

    private static func turnContext(model: String) -> String {
        """
        {"timestamp":"2026-08-29T21:33:28.000Z","type":"turn_context","payload":\
        {"turn_id":"t1","cwd":"/Users/dev/project","model":"\(model)",\
        "approval_policy":"never"}}
        """
    }

    private static let sessionMeta = """
        {"timestamp":"2026-08-29T21:33:27.186Z","type":"session_meta","payload":\
        {"session_id":"01a04f71","cwd":"/Users/dev/project","originator":"codex_cli_rs",\
        "cli_version":"0.151.0","source":"exec","model_provider":"openai"}}
        """

    static let suite = TestSuite("Codex context", [

        // MARK: The reading

        TestCase("The window comes from the harness, so the reading is declared") { t in
            let tail = [
                sessionMeta,
                turnContext(model: "gpt-5.6-sol"),
                tokenCount(last: 16_146, total: 32_187, window: 258_400,
                           at: "2026-08-29T21:37:50.112Z"),
            ].joined(separator: "\n")

            let reading = CodexRolloutScanner.read(tail: tail)
            t.expectEqual(reading?.tokens, 16_146, "tokens")
            t.expectEqual(reading?.window, 258_400, "window")
            t.expectEqual(reading?.confidence, .declared, "confidence")
            t.expectEqual(reading?.model, "gpt-5.6-sol", "model")
            t.expectEqual(reading?.percent, 6, "percent")
        },

        TestCase("It reads the turn's usage, never the session's total") { t in
            // The cumulative figure was twice the window occupancy in the very
            // first rollout measured. A ring drawn from it reads a session as
            // half spent when it has barely started.
            let tail = [
                turnContext(model: "gpt-5.6-sol"),
                tokenCount(last: 16_146, total: 32_187, window: 258_400,
                           at: "2026-08-29T21:37:50.112Z"),
            ].joined(separator: "\n")
            t.expectEqual(CodexRolloutScanner.read(tail: tail)?.tokens, 16_146, "tokens")
        },

        TestCase("The last record wins, even when an earlier line is newer") { t in
            // A resumed session replays its history, so the file is in the order
            // things were written and not in the order they happened. Sorting by
            // clock here would show the state of a conversation from before the
            // resume — the failure a real transcript stepping back nine days
            // established on the Claude side.
            let tail = [
                turnContext(model: "gpt-5.6-sol"),
                tokenCount(last: 200_000, total: 200_000, window: 258_400,
                           at: "2027-01-01T00:00:00.000Z"),
                tokenCount(last: 16_146, total: 32_187, window: 258_400,
                           at: "2026-08-29T21:37:50.112Z"),
            ].joined(separator: "\n")
            t.expectEqual(CodexRolloutScanner.read(tail: tail)?.tokens, 16_146, "tokens")
        },

        TestCase("The model is the one belonging to that count") { t in
            // `turn_context` is written once per turn, so the nearest one above
            // the count is the model that produced it. Taking the first in the
            // file would describe the model a switched session started with.
            let tail = [
                turnContext(model: "gpt-5.1-mini"),
                tokenCount(last: 1_000, total: 1_000, window: 258_400,
                           at: "2026-08-29T21:30:00.000Z"),
                turnContext(model: "gpt-5.6-sol"),
                tokenCount(last: 16_146, total: 32_187, window: 258_400,
                           at: "2026-08-29T21:37:50.112Z"),
            ].joined(separator: "\n")
            t.expectEqual(CodexRolloutScanner.read(tail: tail)?.model, "gpt-5.6-sol", "model")
        },

        TestCase("A rollout with no turn yet has nothing to report") { t in
            t.expectNil(CodexRolloutScanner.read(tail: sessionMeta), "reading")
        },

        TestCase("A GPT model shows G in the ring") { t in
            t.expectEqual(ContextReading.initial(of: "gpt-5.6-sol"), "G", "initial")
            t.expectEqual(ContextReading.initial(of: "claude-opus-5"), "O", "still Claude's")
        },

        TestCase("A declared reading prints its percentage plainly") { t in
            let reading = ContextReading(
                tokens: 16_146, model: "gpt-5.6-sol", window: 258_400,
                confidence: .declared, at: nil
            )
            // No `≥`: that prefix means the figure is a floor, and this one is not.
            t.expectEqual(reading.label, "6%", "label")
        },

        // MARK: The plan allowance

        TestCase("The plan allowance is read, and is not the ring") { t in
            let tail = [
                turnContext(model: "gpt-5.6-sol"),
                tokenCount(last: 16_146, total: 32_187, window: 258_400,
                           at: "2026-08-29T21:37:50.112Z", percent: 12.0),
            ].joined(separator: "\n")

            let usage = CodexRolloutScanner.planUsage(tail: tail)
            t.expectEqual(usage?.usedPercent, 12.0, "percent")
            t.expectEqual(usage?.windowMinutes, 10_080, "window minutes")
            t.expectEqual(usage?.plan, "prolite", "plan")
            t.expectEqual(usage?.sentence, "12% of the 7-day plan used", "sentence")
        },

        TestCase("A fraction of a percent keeps its decimal") { t in
            // Rounding 0.4 to zero would say the allowance is untouched when it
            // is not, and the whole point of the figure is the direction it moves.
            let usage = PlanUsage(usedPercent: 0.4, windowMinutes: 10_080, plan: nil)
            t.expectEqual(usage.sentence, "0.4% of the 7-day plan used", "sentence")
        },

        // MARK: What the harness cannot say

        TestCase("Codex declares the one state it can never report") { t in
            // One and not two. Codex publishes `SubagentStart` and `SubagentStop`
            // like Claude Code does, so the blue waiting state works there; the
            // first draft of this list said otherwise from extrapolation rather
            // than from the published event table, and cost a real feature for an
            // hour. What is genuinely missing is any error event at all.
            t.expectEqual(Harness.codex.cannotReport, [.failed], "blind spot")
            t.expectEqual(Harness.claudeCode.cannotReport, [], "Claude reports everything")
        },

        TestCase("An empty answer clears the rows only when the caller knows it is one") { t in
            // The guard against an empty set exists because the Claude reader
            // cannot tell "nothing is running" from "I could not look", and
            // erasing a whole column on a bad read is unrecoverable. The Codex
            // scanner can tell them apart, so it says so.
            //
            // Without this the last Codex session on a machine kept its row for
            // ever, which is the quietest kind of wrong: everything works until
            // the moment there is only one left.
            let before = TrafficLightState(sessions: [
                "codex-1": SessionState(
                    id: "codex-1", status: .idle, workspace: Workspace(path: "/dev/p"),
                    updatedAt: t0, statusSince: t0, harness: .codex
                )
            ])

            let cautious = StateReducer.reduce(
                before, action: .reconcile(alive: [], harness: .codex), now: t0
            )
            t.expect(cautious.sessions["codex-1"] != nil, "an empty set alone changes nothing")

            let certain = StateReducer.reduce(
                before, action: .reconcile(alive: [], harness: .codex, evenIfEmpty: true), now: t0
            )
            t.expect(certain.sessions["codex-1"] == nil, "and clears it when the caller is sure")
        },

        TestCase("Codex cannot be made red, not even on purpose") { t in
            // The invariant used to hold because no Codex event reached the branch
            // that produces `.failed`, which is a different thing from being true:
            // it depended on which hooks we register rather than on the code, and
            // the header that says which agent a signal belongs to travels on an
            // unauthenticated route.
            let signal = HookSignal(
                sessionId: "codex-1",
                event: .stopFailure,
                cwd: "/dev/project",
                harness: .codex
            )
            let before = TrafficLightState(sessions: [
                "codex-1": SessionState(
                    id: "codex-1", status: .working, workspace: Workspace(path: "/dev/project"),
                    updatedAt: t0, statusSince: t0, harness: .codex
                )
            ])
            let after = StateReducer.reduce(
                before,
                action: .signal(signal, workspace: Workspace(path: "/dev/project"), origin: .editor),
                now: t0.addingTimeInterval(60)
            )
            t.expectEqual(after.sessions["codex-1"]?.status, .working,
                          "the state it had, not the one the event asked for")
        },

        TestCase("Claude is still allowed to fail, which is the point of the list") { t in
            // A guard that refused everything would pass the case above and be
            // useless. The same event on the harness that does publish failures has
            // to go through.
            let signal = HookSignal(
                sessionId: "claude-1",
                event: .stopFailure,
                cwd: "/dev/project",
                harness: .claudeCode
            )
            let before = TrafficLightState(sessions: [
                "claude-1": SessionState(
                    id: "claude-1", status: .working, workspace: Workspace(path: "/dev/project"),
                    updatedAt: t0, statusSince: t0
                )
            ])
            let after = StateReducer.reduce(
                before,
                action: .signal(signal, workspace: Workspace(path: "/dev/project"), origin: .editor),
                now: t0.addingTimeInterval(60)
            )
            t.expectEqual(after.sessions["claude-1"]?.status, .failed, "red where red is real")
        },

        // MARK: Living alongside the other harness

        TestCase("The liveness sweep prunes only the harness it can see") { t in
            // Found by running it, not by reading it. `~/.claude/sessions` holds
            // one file per live Claude Code process and nothing else, so a Codex
            // row is missing from that list the way a cat is missing from a list
            // of dogs. Reconciling across harnesses deleted every Codex row five
            // seconds after the hook that created it — the row appeared in the
            // log, then was gone, with nothing anywhere saying why.
            let workspace = Workspace(path: "/dev/project")
            let now = Date(timeIntervalSince1970: 1_760_000_000)
            let claude = SessionState(
                id: "claude-live", status: .working, workspace: workspace,
                updatedAt: now, statusSince: now, harness: .claudeCode
            )
            let gone = SessionState(
                id: "claude-gone", status: .working, workspace: workspace,
                updatedAt: now, statusSince: now, harness: .claudeCode
            )
            let codex = SessionState(
                id: "codex-live", status: .working, workspace: workspace,
                updatedAt: now, statusSince: now, harness: .codex
            )
            let state = TrafficLightState.empty
                .upserting(claude).upserting(gone).upserting(codex)

            let after = StateReducer.reduce(
                state, action: .reconcile(alive: ["claude-live"], harness: .claudeCode), now: now
            )
            t.expectEqual(after.sessions["claude-live"] != nil, true, "a live Claude row stays")
            t.expectEqual(after.sessions["claude-gone"], nil, "a dead Claude row goes")
            t.expectEqual(after.sessions["codex-live"] != nil, true, "the Codex row is not judged")
        },

        // MARK: The question behind the amber

        TestCase("A Codex permission request carries the command") { t in
            let data = Data("""
            {"session_id":"s","hook_event_name":"PermissionRequest","cwd":"/dev/project",
             "tool_name":"Bash","tool_input":{"command":"git push origin main"}}
            """.utf8)
            let signal = try? HookPayloadDecoder.decode(data, harness: .codex)
            t.expectEqual(signal?.pendingAsk?.sentence, "Bash: git push origin main", "sentence")
        },

        TestCase("A patch shows which file, never its contents") { t in
            // `tool_input` on an `apply_patch` carries the whole file being
            // written. A panel that rendered it blind would put source onto a
            // floating window sitting on top of a shared screen.
            let data = Data("""
            {"session_id":"s","hook_event_name":"PermissionRequest","cwd":"/dev/project",
             "tool_name":"apply_patch",
             "tool_input":{"file_path":"/dev/project/App.swift",
                           "content":"let secret = \\"hunter2\\""}}
            """.utf8)
            let signal = try? HookPayloadDecoder.decode(data, harness: .codex)
            t.expectEqual(signal?.pendingAsk?.sentence,
                          "apply_patch: /dev/project/App.swift", "sentence")
        },

        TestCase("A tool with nothing safe to show still names itself") { t in
            let data = Data("""
            {"session_id":"s","hook_event_name":"PermissionRequest","cwd":"/dev/project",
             "tool_name":"mcp__fs__write","tool_input":{"payload":{"blob":"…"}}}
            """.utf8)
            let signal = try? HookPayloadDecoder.decode(data, harness: .codex)
            t.expectEqual(signal?.pendingAsk?.sentence, "mcp__fs__write", "sentence")
        },

        TestCase("A long command is cut, and says it was") { t in
            let long = String(repeating: "x", count: 300)
            let ask = PendingAsk.from(toolName: "Bash", toolInput: ["command": long])
            t.expectEqual(ask?.detail?.count, PendingAsk.detailLimit + 1, "length with the ellipsis")
            t.expectEqual(ask?.detail?.hasSuffix("…"), true, "the cut is announced")
        },

        TestCase("A multi-line command becomes one line") { t in
            let ask = PendingAsk.from(
                toolName: "Bash", toolInput: ["command": "cat <<'EOF'\nline two\nEOF"]
            )
            t.expectEqual(ask?.detail, "cat <<'EOF' line two EOF", "flattened")
        },

        TestCase("Only the event that carries a question produces one") { t in
            // `tool_name` on a `PostToolUse` names the tool that just finished.
            // Attaching it to the row would show a question nobody asked.
            let data = Data("""
            {"session_id":"s","hook_event_name":"PostToolUse","cwd":"/dev/project",
             "tool_name":"Bash","tool_input":{"command":"ls"}}
            """.utf8)
            let signal = try? HookPayloadDecoder.decode(data, harness: .codex)
            t.expectNil(signal?.pendingAsk?.tool, "no ask")
        },

        TestCase("Codex states its own window; Claude Code does not") { t in
            t.expectEqual(Harness.codex.declaresContextWindow, true, "codex")
            t.expectEqual(Harness.claudeCode.declaresContextWindow, false, "claude")
        },

        TestCase("An unnamed harness is Claude Code") { t in
            // Every hook script written before harnesses existed sends no name.
            t.expectEqual(Harness.named(nil), .claudeCode, "absent")
            t.expectEqual(Harness.named("  "), .claudeCode, "blank")
            t.expectEqual(Harness.named("nonesuch"), .claudeCode, "unknown")
            t.expectEqual(Harness.named("CODEX"), .codex, "case is not a distinction")
        },
    ])
}
