import Foundation

/// The payloads Claude Code really hands to the hooks.
///
/// The shapes are taken from binary 2.1.220, not invented: for instance
/// `SubagentStop` carries `agent_id`, `agent_type` and `last_assistant_message`,
/// while `SubagentStart` only has the first two. A test run that invents the
/// payload verifies its own imagination.
enum HookPayloads {

    static func sessionStart(
        sessionId: String,
        cwd: String,
        source: String = "startup"
    ) -> [String: Any] {
        base(sessionId: sessionId, cwd: cwd, event: "SessionStart")
            .merging(["source": source]) { _, new in new }
    }

    static func userPromptSubmit(sessionId: String, cwd: String) -> [String: Any] {
        base(sessionId: sessionId, cwd: cwd, event: "UserPromptSubmit")
    }

    static func stop(
        sessionId: String,
        cwd: String,
        message: String = "Done."
    ) -> [String: Any] {
        base(sessionId: sessionId, cwd: cwd, event: "Stop")
            .merging(["last_assistant_message": message]) { _, new in new }
    }

    /// A tool starting: a turn the session began on its own, with no prompt.
    static func preToolUse(sessionId: String, cwd: String) -> [String: Any] {
        base(sessionId: sessionId, cwd: cwd, event: "PreToolUse")
            .merging(["tool_name": "Bash", "tool_input": ["command": "true"]]) { _, new in new }
    }

    static func stopFailure(
        sessionId: String,
        cwd: String,
        errorType: String
    ) -> [String: Any] {
        base(sessionId: sessionId, cwd: cwd, event: "StopFailure")
            .merging(["error_type": errorType]) { _, new in new }
    }

    static func notification(
        sessionId: String,
        cwd: String,
        kind: String
    ) -> [String: Any] {
        base(sessionId: sessionId, cwd: cwd, event: "Notification")
            .merging(["notification_type": kind]) { _, new in new }
    }

    static func sessionEnd(sessionId: String, cwd: String) -> [String: Any] {
        base(sessionId: sessionId, cwd: cwd, event: "SessionEnd")
    }

    static func subagentStart(
        sessionId: String,
        cwd: String,
        agentId: String,
        agentType: String = "general-purpose"
    ) -> [String: Any] {
        base(sessionId: sessionId, cwd: cwd, event: "SubagentStart")
            .merging(["agent_id": agentId, "agent_type": agentType]) { _, new in new }
    }

    static func subagentStop(
        sessionId: String,
        cwd: String,
        agentId: String,
        agentType: String = "general-purpose"
    ) -> [String: Any] {
        base(sessionId: sessionId, cwd: cwd, event: "SubagentStop")
            .merging([
                "agent_id": agentId,
                "agent_type": agentType,
                "stop_hook_active": false,
                "last_assistant_message": "subtask complete",
            ]) { _, new in new }
    }

    /// An event generated *inside* a subagent: it carries `agent_id` and must not
    /// move the parent session's traffic light.
    static func toolUseInsideSubagent(
        sessionId: String,
        cwd: String,
        agentId: String
    ) -> [String: Any] {
        base(sessionId: sessionId, cwd: cwd, event: "PreToolUse")
            .merging(["agent_id": agentId]) { _, new in new }
    }

    // MARK: - Internal

    private static func base(
        sessionId: String,
        cwd: String,
        event: String
    ) -> [String: Any] {
        [
            "session_id": sessionId,
            "hook_event_name": event,
            "cwd": cwd,
            "transcript_path": transcriptPath(sessionId),
        ]
    }

    /// Where the fixtures claim the transcript is.
    ///
    /// Under the fake home's `.claude`, because that is the only place the app
    /// will now open one: `TranscriptPathPolicy` refuses anything outside it,
    /// and a fixture in `/tmp` was quietly testing a path production rejects.
    static func transcriptPath(_ sessionId: String) -> String {
        transcriptRoot.appendingPathComponent("projects/e2e/\(sessionId).jsonl").path
    }

    /// Set once by the run, from the fake home the app is given.
    nonisolated(unsafe) static var transcriptRoot = URL(fileURLWithPath: NSTemporaryDirectory())
}
